# Simulated Android main area and keyboard

Follow [the Android procedure](../android-runtime/android-main-area-keyboard.md)
through the production server manager and a real isolated session server.
Run portrait and landscape viewport sizes and supply several inset heights to
the production keyboard layout controller. Verify acknowledged main-area claims,
terminal reflow, bottom-row visibility and preserved Main View across the entire
transition. Also verify a deliberately navigated view is not reset and its
content stays in place on screen, including with a keyboard tall enough to hide
the chrome, and that its saved navigation does not include the keyboard.

The simulated inset is not evidence that a native keyboard opened. Run the APK
case for the Android IME, system bars and physical display scaling. Review the
recording and retained geometry checkpoints before reporting visual continuity.
