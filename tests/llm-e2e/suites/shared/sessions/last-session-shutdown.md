# Last pane closes its session and the final session stops a private server

Closing a session's last pane removes that session. A private local server
stops automatically when its final session ends. Run this scenario with remote
access disabled. Servers with remote access enabled stay available without any
sessions. A session here is a named live server workspace.

Run each close route below on fresh isolated fixtures. Record the frontend,
CLI and server builds, session inventories, terminal IDs, shell PIDs, and server
PID with process birth identities. Use real idle shells with unique output
markers. Observe natural shutdown for at most five seconds after each final
close, before any harness teardown. A hidden window, disconnected socket,
removed descriptor, empty session list, or fixture's successful cleanup alone
cannot establish that a process exited. Zombies do not count as reaped processes.

## Start an isolated local server with two live sessions

1. Use private config/state/cache/data directories and a private connection
   descriptor. Do not connect to, stop, or alter the user's ordinary server.
2. Launch through the production local launcher with no test server running.
   Require automatic server startup and a usable terminal without endpoint,
   password, or Connect input. The server must survive initial startup long
   enough to create the first session.
3. Create a second named session on the same server. Use `gft session list --json`
   to record both sessions and confirm they share one server process. Give
   session A two panes in one tab and another pane in a second tab; session B
   has one pane. Print a distinct marker and `echo $$` in each shell.
4. Keep evidence collection outside these panes so it survives their closure.
   Read-only probes must not launch a server, create a session, or reconnect
   through a path that silently creates a replacement shell.

## Close panes without ending surviving sessions

1. Close one pane in A's two-pane tab with its pane close control. Require only
   that pane and its shell to disappear; both sessions and the server stay alive.
2. Close the remaining pane of that tab. A's other tab and session B still
   work. Closing the last pane of a tab is not the last pane of the session
   while another tab in that session has a pane.
3. Check surviving shell identities and retained output, then type a new marker
   in each. No surviving shell may restart, and no replacement pane may appear.

## Close the last pane of one session

1. With A and B still live, close A's sole remaining pane. Repeat on fresh
   fixtures through the pane close control, pane close shortcut, final-tab
   close shortcut, and shell `exit` (also test EOF with Ctrl+D in an idle shell
   configured to exit on EOF). Exercise final-tab closure with multiple panes
   in that tab as well; all of its shells must exit.
2. Within five seconds, A is absent from `gft session list --json`;
   `gft session has -t A` and `gft session attach -t A` report that it does
   not exist. Neither command may recreate it. No empty live session or
   replacement terminal remains. Every shell closed by the action has exited.
3. B and the original server remain alive with unchanged process identities.
   B retains its output and accepts new input. Repeat with B detached from
   every frontend: its live pane must still keep the server running.
4. Observe A's frontend through the entire close: it leaves the closed session
   without a connection form, unexpected error, or automatic recreation. When
   B is detached, A's window switches to B in place (same native window, B's
   original shell and output) instead of closing or quitting. When B is
   already displayed in another window, A's window closes and B's window
   continues to work. When A had several windows (a moved tab), exactly one
   switches; the others close. The frontend quits only after its final local
   window closes with no parked remote view left to restore.

## Close sessions explicitly

1. Start fresh A and B sessions on one server; give A multiple panes and tabs.
   Run `gft session kill -t A`. Require successful command completion,
   removal of all A's panes and the session, and exit of all its shells. B's
   shell and the original server survive and remain usable.
2. Run `gft session kill -t B` from an external control process. Require
   successful command completion and natural server exit within five seconds,
   with every owned shell gone. A shutdown race must not turn a successful
   close into a CLI connection error. Repeat with the final session detached.
3. If the frontend exposes an explicit close-session action, repeat through
   that action and require the same inventory and process results. In Godot,
   use Sessions panel → right-click the displayed session → Kill Session with
   one window open: the window must stay open and show the other session, and
   killing that last session then quits the app as the server stops. Closing a
   presentation window that only detaches is covered separately below.

## Close the last pane of the last session

1. Start a fresh server with exactly one live session. Repeat each pane, tab,
   and shell-exit route from the earlier stage, including a final tab holding
   several panes. Require session removal, shell exit, and automatic server
   exit within five seconds. Also run shell `exit` after detaching the frontend,
   using delayed shell input arranged before detachment.
2. Keep a second observer client attached in one run. An open client connection
   must not keep a server alive after its last live session closes. All attached
   views must handle the normal closure without an unexpected diagnostic.
3. Verify the exact server and shell process identities are gone, the server's
   IPC endpoint and any TCP listener no longer accept connections, and no live
   connection descriptor advertises that owner. Observe for another five
   seconds: no reconnect loop may restart the server or spawn a replacement
   session. Saved checkpoints do not count as live sessions keeping it alive.
4. Capture exit status where the process is owned by the harness; normal
   shutdown must succeed. Sending terminate/kill signals, invoking a server-stop
   command, or letting a fixture destructor stop the owner is failure cleanup,
   never evidence that automatic shutdown passed.

## Preserve detached sessions and restart after automatic shutdown

1. On a fresh fixture, close all frontend windows using the ordinary detach
   path while a session still has a live pane. Require the server and shell
   to survive. Reattach with `gft session attach -t NAME` and verify the same
   terminal ID, shell identity, and retained output, then type a new marker.
2. Close that session's last pane and verify natural server shutdown as above.
   Launch normally again using the same isolated config/state. Require a new
   server identity and one fresh, usable session with exactly one new shell,
   without cleanup commands, stale-lock errors, or a Connect form. No closed
   session or pane may reappear. Close its last pane and verify shutdown again.
3. Save a result for each frontend and close route with timestamped inventories,
   command results, process/listener observations, logs, and recordings of UI
   closure and restart. Record failures before cleaning up only owned resources.
   Report BLOCKED for missing execution or evidence; another frontend's result
   or a test that kills the server during teardown cannot certify this case.

`tests/server/test_last_session_shutdown.py` checks the shared owner through pane/tab
commands, CLI kill, shell exit/EOF, an attached observer, and detached sessions.
It waits for the actual owned child to exit before fixture cleanup, verifies
shell reaping and IPC removal, and checks that the dev launcher no longer prompts.
Godot's `tests/godot/local_startup_e2e.py` close scenarios and
`tests/godot/tab_window_e2e.py --scenario close --gpu` likewise require natural owner
exit before teardown; the latter drives the final window's Kill Server action
(`--scenario close-server`), while `--scenario close` checks that Detach keeps the
owner running.
These are partial adapters. Follow this procedure for the full launch/relaunch
and visual evidence, and for frontends without a bound adapter.

On Windows, `tests/platform/windows/windows_relaunch_e2e.py --godot <non-console-exe>
--shell powershell.exe --evidence <new-directory>` records two real frontend
launches using the same private state. Repeat with `--shell pwsh.exe`. It does
not pre-start a test owner: the production frontend creates the server. It
retains Windows process handles and birth times before requesting shell exit,
observes natural shutdown before cleanup, and verifies a fresh usable shell on
relaunch. This covers the shell-exit/relaunch route; the other close controls,
multiple-session routes, and capture review remain separate requirements.
