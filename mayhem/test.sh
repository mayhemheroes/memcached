#!/usr/bin/env bash
#
# memcached/mayhem/test.sh — RUN memcached's own `testapp` suite (built by mayhem/build.sh with
# normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: testapp is memcached's real unit + integration suite. The first cases are
# known-answer/assert tests (cache, stats_prefix, safe_strto* number parsing, crc32c); the remaining
# cases spawn the actual ./memcached-debug server and drive the binary protocol end-to-end (set/get/
# add/replace/delete/incr/decr/append/prepend/flush/stat/...), asserting the server's responses byte
# for byte. A no-op / "exit(0)" patch (or any change that breaks parsing, storage, or the protocol)
# makes testapp print "not ok" and return non-zero. This script only RUNS the pre-built binary via
# TAP output; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BUILDDIR/testapp" ]; then
  echo "missing $BUILDDIR/testapp — run mayhem/build.sh first" >&2
  emit_ctrf "memcached-testapp" 0 1 0; exit 2
fi

echo "=== running testapp in $BUILDDIR ==="
# testapp expects to find ./memcached-debug and ./timedrun in cwd (it spawns the real server for the
# binary-protocol integration cases).
out="$(cd "$BUILDDIR" && ./testapp 2>&1)"; rc=$?
echo "$out"

# Parse TAP: "ok N - desc", "not ok N - desc", "ok # SKIP N - desc".
PASS=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+ - ' || true)
SKIP=$(printf '%s\n' "$out" | grep -cE '^ok # SKIP ' || true)
FAIL=$(printf '%s\n' "$out" | grep -cE '^not ok [0-9]+ - ' || true)
: "${PASS:=0}" "${SKIP:=0}" "${FAIL:=0}"

# If no TAP lines parsed, fall back to testapp's exit code as the verdict.
if [ "$(( PASS + SKIP + FAIL ))" -eq 0 ]; then
  echo "could not parse testapp TAP output; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "memcached-testapp" 1 0 0; exit 0; }
  emit_ctrf "memcached-testapp" 0 1 0; exit 1
fi

# A non-zero testapp exit with no "not ok" line means it aborted mid-run (e.g. a failed assert that
# never printed a TAP line) — count that as a failure so the oracle can't be gamed.
if [ "$rc" -ne 0 ] && [ "$FAIL" -eq 0 ]; then
  FAIL=1
fi

emit_ctrf "memcached-testapp" "$PASS" "$FAIL" "$SKIP"
