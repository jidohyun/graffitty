For Godot, run `python3 tests/godot/tab_window_e2e.py --scenario close` and
`--scenario close-server`, each with a fresh, short `--evidence` directory.
Use the private server, real shells, private Chromium surface and loopback
remote host. Do not send desktop input to personal windows or rebuild any
executable during the test.

In Godot, × never ends a session, not even one idle pane: it always asks. Local
windows offer exactly **Kill Server** (`서버 강제 종료`), **Detach** and
**Cancel**, with Cancel focused; Enter cancels, as does Escape. Both preserve
exact shell/job birth identities. Inspect the actual dialog capture for
readable warning text and separate buttons. Detach closes only the window and
keeps every session and shell alive; detaching the final window quits the app
while the server keeps running. Kill Server ends attached and detached sessions
on that local server, which then exits. Remote windows offer only Detach and
Cancel and must not offer server shutdown;
the server must reject `close_server` from WebSocket clients, even authenticated
loopback clients. `test_live_sessions.py` exercises that rejection, local cleanup,
and survival of a separate remote server using disposable real servers.

Retain response traces, process birth identities, hashes and actual images.
Write a separate visual-review.json naming the actual captures inspected.
