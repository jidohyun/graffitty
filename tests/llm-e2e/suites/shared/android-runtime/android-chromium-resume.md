# Browser video after Android resumes

Run on a physical Android device against each browser backend with hardware video.
The runner sends the real APK to the background for eleven seconds, returns it to
the foreground, and repeats. Check that the browser PID and JavaScript document
survive, the connection recovers, and fresh hardware-decoded frames arrive without
browser or decoder errors. Preserve runtime state, logcat and the server log.
