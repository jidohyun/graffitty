# Switch between live sessions

Use a private server and two named live sessions. Record the original terminal
IDs, PIDs, text, focus, camera and tab membership. Split a pane and open a second
native window, then create another session and switch back through the native
session picker or `$session` completion. The original shells, environment,
scrollback and each window's presentation must survive.

Give the two sessions different manual pans and zoom levels. Switch immediately
after navigating, before any autosave delay, through the CLI, Sessions panel and
`$session` picker. Each return must restore its own viewport without refitting
Main View or inheriting the other session's camera. Repeat with several tabs and
with a second client displaying a different view of the same session. A session
left in Main View stays fitted; a newly created session starts fitted. Failed
switches leave the current viewport intact. Repeat in Android's managed workspace
and record simulated and physical-device results separately.

Run `gft session attach -t <name>` in the original real PTY. It must redirect the client
that supplied that input. Keep another client attached throughout and verify
that it remains authorized to view its original session's terminals.

Attempt an unknown session and a duplicate new-session name. Display the owner
error and keep the current terminal usable. Create a detached session and
verify that it appears in the live menu without switching the current view.
Keep the owner and client binaries frozen and retain screenshots and transcripts.

Repeat with **Fly away** and **Fly away and in** in Flat 2D and a 3D world.
Camera travel must end at the restored session view. After both sessions have
been running for two seconds, CPU and RAM must appear with the destination
panes, including a session never viewed before. Inactive terminal sessions keep
sampling; switching must not reset their CPU baseline or wait for a periodic
resource update. Check that displayed PIDs and metrics belong to the destination.
