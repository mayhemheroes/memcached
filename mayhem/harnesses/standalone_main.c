/* Standalone (non-libFuzzer) reproducer driver for the memcached fuzz harnesses.
 * Reads one input file and feeds it to LLVMFuzzerTestOneInput once, so a crashing
 * input found by Mayhem/libFuzzer can be replayed under a debugger without the
 * fuzzing runtime. Built into /mayhem/<harness>-standalone by mayhem/build.sh.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerInitialize(int *argc, char **argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
    /* run the harness's one-time global init (proxy conn / lua VM / hashing) */
    LLVMFuzzerInitialize(&argc, argv);

    if (argc != 2) {
        fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "failed to open %s\n", argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) { fclose(f); return 2; }
    uint8_t *data = malloc((size_t)size ? (size_t)size : 1);
    if (!data) { fclose(f); return 3; }
    size_t r = size ? fread(data, (size_t)size, 1, f) : 0;
    fclose(f);
    if (size && r != 1) { fprintf(stderr, "read failed\n"); free(data); return 4; }

    LLVMFuzzerTestOneInput(data, (size_t)size);
    free(data);
    return 0;
}
