// Built/run by tests/chromium/chromium_android_decode.py using the production decoder.
#include "../../crates/transport/chromium-video/src/android.c"
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    printf("PID %d\n", getpid()); fflush(stdout);
    int expected_width = atoi(argv[4]), expected_height = atoi(argv[5]);
    Video *video = gv_decoder_named(atoi(argv[2]), argv[3], expected_width, expected_height);
    if (!video) return 3;
    FILE *input = fopen(argv[1], "rb");
    if (!input) { gv_free(video); return 4; }
    uint8_t *bytes = malloc(8 * 1024 * 1024);
    if (!bytes) { fclose(input); gv_free(video); return 5; }
    uint32_t length; unsigned packets = 0, frames = 0; int error = 0;
    // The decoder owns each returned frame until its next call.
    const uint8_t *frame = NULL; int width = 0, height = 0;
#define PRESENT(result) do { \
        if ((result) < 0) error = 7; \
        else if ((result) > 0 && (width != expected_width || height != expected_height)) error = 9; \
        else if ((result) > 0) ++frames; \
    } while (0)
    while (!error && fread(&length, sizeof(length), 1, input) == 1) {
        if (!length || length > 8 * 1024 * 1024 || fread(bytes, length, 1, input) != 1) { error = 6; break; }
        // Match the production Rust worker: retain a packet the codec cannot
        // accept yet, present pending output, then retry after a short wait.
        int result, retries = 0;
        while ((result = gv_decode(video, bytes, (int)length, GV_NV12, &frame, &width, &height)) == -2 && retries++ < 2500) {
            int polled = gv_decode(video, NULL, 0, GV_NV12, &frame, &width, &height);
            PRESENT(polled);
            if (error) break;
            usleep(4000);
        }
        if (error) break;
        PRESENT(result);
        ++packets;
    }
    for (int poll = 0; !error && poll < 125; ++poll) {
        int result = gv_decode(video, NULL, 0, GV_NV12, &frame, &width, &height);
        PRESENT(result);
        usleep(4000);
    }
    printf("RESULT {\"packets\":%u,\"frames\":%u,\"error\":%d}\n", packets, frames, error);
    free(bytes); fclose(input); gv_free(video); return error;
}
