#!/usr/bin/env bash
#
# memcached/mayhem/build.sh — build memcached's OSS-Fuzz proxy-protocol fuzz harness as a sanitized
# libFuzzer target (+ a standalone reproducer), AND memcached's own `testapp` unit/integration suite
# (normal flags) for mayhem/test.sh.
#
# Fuzzed surface (fuzzer_proxy):
#   try_read_command_proxy(conn*) -> proxy_process_command() -> process_request() in proto_parser.c.
#   Each input is one memcached command line (text + meta protocol: get/set/cas/incr/mg/ms/ma/...,
#   must contain a '\n'). The harness sets up an always-on proxy connection (lua VM, worker thread,
#   hashing) once in LLVMFuzzerInitialize and feeds bytes into the connection read buffer per call.
#   Inputs are protocol command bytes, NOT a file format.
#
# Two build trees (the harness and the test suite have incompatible needs):
#   HARNESS tree  : memcached.c's main() renamed to main2 (libFuzzer provides main); compiled with
#                   $SANITIZER_FLAGS + -fsanitize=fuzzer-no-link so the parser is coverage-instrumented.
#   TEST tree     : pristine main() (testapp spawns the real memcached-debug server); NORMAL flags so
#                   test.sh stays an honest PATCH oracle, free of sanitizer/benign-UB noise.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
# -fno-sanitize=alignment: murmur3_hash.c does deliberate unaligned 32-bit loads (a benign UBSan
# 'alignment' check that fires on ~every input and would abort before the fuzzer can explore). ASan +
# the rest of halting UBSan stay on. Narrow relax, documented per PORTING.md.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-sanitize=alignment -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# Objects the harness links against (the memcached- prefixed objects produced by `make` with proxy on).
MC_OBJS=(
  memcached-memcached.o memcached-hash.o memcached-jenkins_hash.o memcached-murmur3_hash.o
  memcached-slabs.o memcached-items.o memcached-assoc.o memcached-thread.o memcached-daemon.o
  memcached-stats_prefix.o memcached-util.o memcached-cache.o memcached-bipbuffer.o memcached-base64.o
  memcached-logger.o memcached-crawler.o memcached-itoa_ljust.o memcached-slab_automove.o
  memcached-slabs_mover.o memcached-authfile.o memcached-restart.o memcached-proto_text.o
  memcached-proto_bin.o memcached-proto_parser.o memcached-proto_proxy.o memcached-mcmc.o
  memcached-proxy_xxhash.o memcached-proxy_ustats.o memcached-proxy_ratelim.o memcached-proxy_jump_hash.o
  memcached-proxy_request.o memcached-proxy_result.o memcached-proxy_inspector.o
  memcached-proxy_mutator.o memcached-proxy_network.o memcached-proxy_lua.o
  memcached-proxy_luafgen.o memcached-proxy_config.o memcached-proxy_ring_hash.o
  memcached-proxy_internal.o memcached-proxy_tls.o memcached-md5.o
  memcached-extstore.o memcached-crc32c.o memcached-storage.o memcached-slab_automove_extstore.o
)

# ── vendor blobs (lua) are fetched once into the source tree; share them with both build trees ──────
if [ ! -f "$SRC/vendor/lua/Makefile" ]; then
  ( cd "$SRC/vendor" && sh ./fetch.sh )
fi

# Snapshot the source tree into a sibling dir, excluding the build trees themselves and .git
# (so a tree inside $SRC isn't copied into itself, and we don't duplicate history twice).
snapshot_to() {
  local dst="$1"
  rm -rf "$dst"; mkdir -p "$dst"
  tar -C "$SRC" --exclude='./mayhem-harness' --exclude='./mayhem-tests' --exclude='./.git' -cf - . \
    | tar -C "$dst" -xf -
}

# ── 1) HARNESS tree: sanitized + coverage-instrumented proxy build, then link the libFuzzer target ──
HBUILD="$SRC/mayhem-harness"
snapshot_to "$HBUILD"
( cd "$HBUILD"
  # libFuzzer provides main(); rename memcached.c's so the harness link doesn't get two mains.
  sed -i 's/^int main (int argc, char \*\*argv) {/int main2 (int argc, char **argv) {/' memcached.c
  [ -f vendor/lua/Makefile ] || ( cd vendor && sh ./fetch.sh )
  ./autogen.sh >/dev/null
  # Instrument the project (the fuzzed parser) with sanitizers + SanitizerCoverage.
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1" \
    ./configure --enable-proxy >/dev/null
  # Build liblua + ONLY the memcached-*.o objects the harness links against. We never link the
  # `memcached`/`memcached-debug` binaries here (main() is renamed for the harness), so we skip
  # those final links entirely by naming the object targets explicitly.
  make -j"$MAYHEM_JOBS" -C vendor/lua >/dev/null 2>&1 || ( cd vendor && make >/dev/null )
  make -j"$MAYHEM_JOBS" "${MC_OBJS[@]}" >/dev/null

  # libFuzzer target -> /mayhem/fuzzer_proxy
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I. -Ivendor/lua/src -DHAVE_CONFIG_H -O1 -pthread \
      "$HARNESS_DIR/fuzzer_proxy.c" $LIB_FUZZING_ENGINE \
      "${MC_OBJS[@]}" vendor/lua/src/liblua.a -levent -lm -ldl \
      -o /mayhem/fuzzer_proxy

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/fuzzer_proxy-standalone
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I. -Ivendor/lua/src -DHAVE_CONFIG_H -O1 -pthread \
      "$HARNESS_DIR/fuzzer_proxy.c" "$HARNESS_DIR/standalone_main.c" \
      "${MC_OBJS[@]}" vendor/lua/src/liblua.a -levent -lm -ldl \
      -o /mayhem/fuzzer_proxy-standalone
)
echo "built fuzzer_proxy (+ standalone)"

# ── 2) TEST tree: memcached's own testapp suite with NORMAL flags (test.sh only RUNS it) ────────────
#      testapp links against the project; it also spawns the real ./memcached-debug for the binary-
#      protocol integration tests, so we build memcached-debug + sizes + testapp + timedrun. Pristine
#      main() and normal flags keep it a clean, honest oracle.
TBUILD="$SRC/mayhem-tests"
snapshot_to "$TBUILD"
( cd "$TBUILD"
  [ -f vendor/lua/Makefile ] || ( cd vendor && sh ./fetch.sh )
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS ./autogen.sh >/dev/null
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS ./configure --enable-proxy >/dev/null
  # `make` builds liblua + the project; then the unit/integration test binaries.
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS" >/dev/null
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make sizes testapp timedrun memcached-debug >/dev/null
)
echo "built memcached testapp suite in mayhem-tests/"

echo "build.sh complete:"
ls -la /mayhem/fuzzer_proxy /mayhem/fuzzer_proxy-standalone 2>&1 || true
ls -la "$TBUILD/testapp" "$TBUILD/memcached-debug" 2>&1 || true
