// Private chromium-level CDP transport. Chromium owns fd 3/4; only this process
// holds their other ends. No remote-debugging TCP listener is opened.
#include <fcntl.h>
#include <set>
#include <cerrno>

static int playwrightRead = -1, playwrightWrite = -1;
static dispatch_source_t playwrightSource;
static std::string playwrightInput, playwrightOutput;
static constexpr size_t playwrightLimit = 32 * 1024 * 1024;

static bool preparePlaywrightPipe() {
    int input[2], outputPipe[2];
    if (pipe(input) || pipe(outputPipe)) return false;
    // Move all descriptors away from Chromium's fixed fd 3/4 first.
    int readEnd = fcntl(input[0], F_DUPFD_CLOEXEC, 10);
    playwrightWrite = fcntl(input[1], F_DUPFD_CLOEXEC, 10);
    playwrightRead = fcntl(outputPipe[0], F_DUPFD_CLOEXEC, 10);
    int writeEnd = fcntl(outputPipe[1], F_DUPFD_CLOEXEC, 10);
    for (int fd : {input[0], input[1], outputPipe[0], outputPipe[1]}) close(fd);
    if (readEnd < 0 || writeEnd < 0 || playwrightRead < 0 || playwrightWrite < 0) return false;
    if (dup2(readEnd, 3) < 0 || dup2(writeEnd, 4) < 0) return false;
    close(readEnd); close(writeEnd);
    fcntl(playwrightRead, F_SETFL, O_NONBLOCK);
    fcntl(playwrightWrite, F_SETFL, O_NONBLOCK);
    // A closing Chromium pipe must not terminate the owner via SIGPIPE.
    fcntl(playwrightWrite, F_SETNOSIGPIPE, 1);
    return true;
}

static void playwrightSend(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (playwrightOutput.size() + data.length + 1 > playwrightLimit) return;
    playwrightOutput.append((const char *)data.bytes, data.length);
    playwrightOutput.push_back('\0');
}

static void pollPlaywrightPipe() {
    if (playwrightRead < 0) return;
    while (!playwrightOutput.empty()) {
        ssize_t n = write(playwrightWrite, playwrightOutput.data(), playwrightOutput.size());
        if (n <= 0) break;
        playwrightOutput.erase(0, n);
    }
    char buffer[65536];
    // Bound work per UI tick, including screenshots and large DOM responses.
    for (int i = 0; i < 128; ++i) {
        ssize_t n = read(playwrightRead, buffer, sizeof(buffer));
        // Chromium closed its end: stop the read source rather than waking
        // continuously on end-of-file or error. Owner shutdown follows its exit.
        if ((n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) && playwrightSource) {
            dispatch_source_cancel(playwrightSource);
            playwrightSource = nil;
        }
        if (n <= 0) break;
        playwrightInput.append(buffer, n);
    }
    size_t offset = 0, end;
    while ((end = playwrightInput.find('\0', offset)) != std::string::npos) {
        NSData *data = [NSData dataWithBytes:playwrightInput.data() + offset length:end - offset];
        NSMutableDictionary *message = [NSJSONSerialization JSONObjectWithData:data
            options:NSJSONReadingMutableContainers error:nil];
        offset = end + 1;
        if (![message isKindOfClass:NSDictionary.class]) continue;
        serverReply(message);
    }
    playwrightInput.erase(0, offset);
    if (playwrightInput.size() > playwrightLimit) closeAll();
}
