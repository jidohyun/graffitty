# Sessions

A session is a workspace containing tabs, panes, and their running programs.
Use separate sessions for different projects or tasks.

## Switch sessions

Open **Sessions (<img class="menu-icon" src="../images/menu/panels-top-left.svg" alt="" width="18" height="18">) → All Sessions…** to see sessions on this computer and connected servers.
Switching sessions leaves the others running.

## Leave and return

Clicking × in a connected window offers **Detach**, which closes the window
and keeps its session and programs running. A window connected directly to
the local server also offers **Kill Server**.
Reopen the session from **All Sessions…** to continue where you left off.

Detached programs still depend on the server computer staying awake and running.
A reboot ends them.

## From the command line

Create a named session and open it:

```sh
gft session new -s work
```

To create it in the background instead:

```sh
gft session new -d -s build -c /path/to/project
```

List running sessions and return to one:

```sh
gft session list
gft session attach -t work
```

- Inside Graffitty, `attach-session` switches the calling window.
- Outside Graffitty, it opens a window for that session.
- Use the session's name or its `$ID` from the listing. Quote IDs, for example `-t '$12'`.
- `gft session list --json` prints session records for scripts.

In the **Sessions** panel, right-click a session and choose **Rename Session**
to edit its name in place. Press **Enter** or click outside the field to save. Press **Esc** to cancel.
Renaming an inactive session keeps your current session selected.

You can also rename a session from the command line.

```sh
gft session rename -t work project
```

## End a session

Right-click a session in the **Sessions** panel and choose **Kill Session** to
end that session and all its panes and programs. Closing a session's last pane
also ends that session. A standalone Chromium pane can keep the session open
after its last terminal closes.

From the command line, `gft session kill -t project` ends the named session.
Other sessions, including detached ones, keep running. A private server exits
automatically when its final session ends. A server with remote access enabled
stays online even when it has no sessions.
The close confirmation tells you whether the server will stop when the session ends.

**Kill Server** stops the local server and ends every session it hosts,
including detached ones.

When the session a window shows ends this way, or through its last pane, the
window switches to another session that no other window is showing. If every
remaining session is already open elsewhere, the window closes. Graffitty
quits only when no session or connected server is left to show.
