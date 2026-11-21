#include <signal.h>

extern "C" void graffitty_restore_sigint() {
    struct sigaction action = {};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, nullptr);
}
