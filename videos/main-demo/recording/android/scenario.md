# Android agent handoff demo

This is the source scenario for `AndroidDemo.gd`, following the repository's
LLM E2E specification → replay workflow. The replay extends the same Android
workspace scenario as the simulated and APK E2E tests. Use its shared
`connect_graph_ports` action; do not replace interactions with graph RPC edits
or hard-coded pane rectangle assignments.

## Launch two agents

Start in an isolated `/home/demo` Podman shell using the mobile UI profile,
either in desktop Godot or on the connected Fold7.
Click the visible right-split button. Type `codex` and `claude` quickly in their
respective focused panes. Do not show Git setup commands or pause after launch.
The opening must not briefly enter pane inspection or show a focus outline.

## Move outside Main View

Use one quick two-finger gesture with visible indicators to establish the overview. Frame the complete route
and drag both pane headers below Main View. Keep both panes on screen throughout
the moves. Use the panes' current geometry, not assigned coordinates. Keep Codex
narrow and Claude at its natural post-move size. Do not resize Claude afterward.
Zooming and reordering use the fast pacing established in this demo.

For every later close-up, double tap the pane title bar with visible touch circles.
Double tap the same title again to return to the original overview, then double
tap the next pane. Use the production fit/return animation; never animate camera
coordinates directly or repeat pinch-and-pan strokes between panes.

## Create Slack before prompting

Frame Claude's actual header controls and tap its right-split button with a
visible touch circle. Never draw a mouse arrow on Android. Let pane physics place the new neighbor. Existing panes must
retain their sizes; the new pane inherits Claude's size. Follow it with the camera.
Drag Slack a little farther right, visibly, to leave space for its incoming wire.
Immediately fit and focus the new pane, then type `gft node slack-send` with no added hold or redundant framing. In this isolated recording shell,
that spelling aliases `gft dev slack-send-demo`; use the real Slack Send form,
queue and log, without sending a network notification.

## Connect the named ports

Use actual UI drags from Codex's Turn completed output to Claude's Receive input,
then from Claude's Send output to Slack's input. Both connections must exist before
any review prompt is typed. Resolve sockets by pane and port IDs at their current
positions. Use the shared Android E2E drag arc so nearby sockets exceed touch slop.
Verify each named edge and stop on failure rather than continuing the recording.

## Prepare the reviewer, then run the sender

Focus and frame Claude closely before typing:

> Graffitty will send turn completed payload. Review if it's done right. If not, send me on Slack.

Wait until Claude says it is ready and becomes idle. Only then focus/frame Codex
and type:

> Implement a website following the spec

Both mock input boxes wrap long prompts into multiple visible lines. Return to the
overview and frame Codex and Claude together while the completion travels between
them. Once Claude receives it, use one visible two-finger gesture to frame Claude
and Slack before the findings appear. The completion
must deliver the same full event envelope as native agents, including the actual
Codex session file path and checkpoint. Claude reads that session, identifies the
three missing requirements, and queues its output to Slack. Show Slack's delivered
log and then the three connected nodes. All terminal input must target the focused
pane; unexpected errors or dialogs fail the take.
Record the notification cue when the `DELIVERED` log appears, after the queue
acknowledgment, so recompositing cannot make the notification arrive early.

## Capture and review

Record the mobile UI at 1968×1968 application resolution in desktop Godot, or
capture the physical Fold7 at its native 1968×2184 ratio. Produce the final
60fps video with the straight-on one-second Blender unfold followed by the
live screen overlay. The compositor supplies Android system bars and the
Slack notification; desktop capture does not test the Android OS or IME.
Review the continuous recording, especially clicks, drags, size preservation,
prompt legibility, readiness order and both graph edges. A still image is not
sufficient evidence of smooth interaction.

Use `videos/main-demo/recording/android/desktop.py --output <directory>` without
a device. For physical-device capture, use `record.py` instead. Add
`--through-wiring` for a focused
wiring rehearsal. Omit `--through-wiring` for the complete sequence. Use
`--skip-export` only for physical-device capture when the shared APK code has not changed.

Keep the centered three-node overview visible during the Codex/Claude/Slack explanation. Label the panes above their titles: Implement, Reviewer, Slack notification. Connect the wires during the explanation, and finish the role explanation in this overview, then double-tap Claude’s title to type the reviewer prompt in close-up. Android connection must preserve the exact viewport dimensions; settle startup layout off the capture clock. Never speed up playback.

Role labels fade and rise over 0.30 seconds on entry, with a 0.04-second stagger; fade and rise out over 0.22 seconds before zooming into Claude. Mock thinking lasts only 0.25–0.40 seconds per step. Shorten actual waits and typing, never playback.

During “Each terminal pane can advertise itself as a node”, keep both agents visible to click the split control; frame the new three-node group directly. Do not double-tap into Claude or Slack during graph setup. Reserve the first close-up for typing Claude’s instructions.

Before Claude reports the missing requirements, frame Claude and Slack together. Keep both panes and their connection visible while Claude finishes the findings, queues the message, and Slack receives it. Hold the complete list for at least three seconds in this shared view; do not switch to a Slack close-up after delivery.
