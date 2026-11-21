# Automatic local startup

This is a strict shared product requirement. A local user opens the application
and gets a terminal; the server/client architecture must not require them to set
up a server, enter an endpoint/password, or click Connect. Run and report this
case independently for every required frontend.

## Automatic local launch

1. Use isolated application config/state and the production development launcher
   (`mise dev` for Godot), with no existing test server or connection descriptor.
   Do not stop the user's normal server or modify their workspace.
2. Record the complete launch. Require automatic local owner startup, authenticated
   attachment and a visible focused terminal, without any connection/setup form.
3. Type a unique marker and verify output. Record server/PTY identities and the
   frontend build. The terminal must be usable immediately after startup.
4. Launch again with `--new-session` from a different directory. Require a
   fresh server session with exactly one pane in that directory (or the
   explicitly configured directory). The first session and its shell must
   remain intact.
5. Launch again without arguments. The application's first window returns to
   the session a frontend showed last, with the same panes and no new shell.

## Empty workspace recovery and retained sessions

1. Prepare an empty workspace fixture before its first terminal is created.
   Explicitly select that workspace. Require automatic creation of one usable
   terminal; an empty initial workspace must not show the remote Connect form.
   Closing the last pane of an established live session instead removes that
   session, as specified in [last-session shutdown](../sessions/last-session-shutdown.md).
2. Repeat with an existing live terminal containing a unique marker. Detach and
   use `gft session attach -t NAME` to reopen it; require the same terminal ID, shell PID and retained
   output, with no duplicate terminal created.
3. On a freshly opened window, the Main View border stays hidden throughout
   startup. Zoom out to reveal it and return to Main View to hide it again.
   Type into the terminal: configured camera tilt and depth-of-field effects
   must still work when the server's page size differs from the window size.
   Resize the local desktop window between portrait and landscape: its tiled
   main area must fill both available dimensions, with additional terminal rows
   or columns instead of a scaled, fixed-size page. The server must retain that
   updated area. Remote mirrors keep fitting the shared area without resizing
   the owner's PTY just because their own window or on-screen keyboard changes.
4. Close the last pane with the pane shortcut, then repeat in a fresh session
   with the tab shortcut and with shell `exit`. Each closes that window; the
   final window quits the application. No replacement shell may be created,
   and other windows and their shells must remain alive.
   The closed session must be removed from the live session inventory; closing
   the server's final live session must also stop the server automatically.
   Follow the linked lifecycle case to verify server exit before fixture cleanup.
5. Keep the connection dialog under observation throughout, including transient
   appearances. No credentials, endpoint entry or Connect click is allowed.
6. Close only the test frontend and clean up the owned test resources. Report
   PASS only with the recording and session evidence; unexpected errors fail.

`tests/godot/local_startup_e2e.py` is a supporting Godot regression: it creates
an empty workspace on a real isolated owner, loads the production entry scene,
checks no connection dialog appears, sends real terminal input, and verifies
explicit reattachment preserves the shell without duplication, then verifies
two `--new-session` launches get independent single-pane sessions and the
correct cwd, and an ordinary launch returns to the session shown last.
With `--gpu`, it also checks 85% background opacity using a hidden Metal window.
The `--scenario close-pane`, `close-tab`, and `shell-exit` cases check startup
framing and natural application exit. With `--gpu`, they also send real keyboard
input and compare rendered text with depth-of-field enabled and disabled at the
same camera pose.
It does not certify visible keyboard focus or the other frontends.
