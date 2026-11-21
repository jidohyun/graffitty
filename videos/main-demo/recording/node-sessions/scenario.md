# Prepared node sessions in Bistro World

Record one continuous desktop recording using `NodeSessionsDemo.gd`. Prepare Parallel,
SystemOne, and the GGP example off camera, in that order, in Bistro World. Before
the delivered edit, prepare the Parallel reviewer and start the three workers, then
click the SystemOne session. The Parallel fixtures use their own `parallel-clock`;
the replay freezes it while SystemOne is on camera, so the workers are still running
when their session returns.

The delivered edit opens on the arrived SystemOne graph. After that demonstration,
move the pointer to the Parallel session in the compact left sidebar and click it.
Parallel's clock resumes on that approach, its narration starts on the click, and
only the two approved Parallel narration lines are used. After the combined handoff,
click the Custom nodes session to reveal the prepared GGP inspector and Python
example. Keep both session-click transitions continuous. The
Python node still starts and connects during its spoken instructions.

Run:

```sh
python3 videos/main-demo/recording/systemone/record.py --chapter node-sessions --output videos/main-demo/assets/takes/node-sessions/TAKE
python3 videos/main-demo/recording/node-sessions/split_take.py videos/main-demo/assets/takes/node-sessions/TAKE
```

For a film including Watcher, use `recording/watcher/record.py --output TAKE`
and run this same splitter on that complete take. It retains the same four
session entries throughout all node chapters and saves the uppercase source
separately from the Watcher source. Append its `watcher` child take last.

Append the resulting child takes in film order: `systemone`, then `parallel`
(`--start-frame 0`), then `protocol`. Then check the composition
and render with `refresh_nodes.py --nodes-only`, preserving the accepted desktop,
Android chapter, and native Chromium cursor fix.

Never accelerate playback. Trim only the off-camera setup, keep every retained
frame at 60 fps, and use actual pointer movement and clicks for the session changes.
Do not recapture Chromium. Narration must say “Connect the nodes.” fluently,
without filler, hesitation, or a trailing vocalization.

Bistro uses Castle's mild effects preset. Preserve the older graph's relative
pane sizes and spacing, but place all three graphs horizontally clear of Main View so
its outline never enters the overview. Parallel and SystemOne sit to its left; the
Custom nodes session sits to its right, in front of the dining-room chairs. Keep the camera steady while waiting
for completions. Ease out to the complete graph before clicking the Custom nodes session.
Keep the session-switch departure and arrival effects at their natural speed.
Every authored graph pan/zoom must use the workspace's pinch navigation path,
which interrupts the active adaptive projection. Measure displayed bounds so
the chosen graph still fits when the current typing correction is frozen.
After each move, assert that the camera lens, eye, and direction stay fixed
until new typing. Measure the camera rather than the animated sheet surface.
This applies to SystemOne, GGP, and Watcher alike.
Keep adaptive mode enabled when manually framing Parallel's running workers;
disabling it at that moment starts a separate return-to-rest animation.
The GGP and Watcher explanations hold camera effects explicitly; changing the
fixed zoom setting alone does not disable adaptive fitting. Keep the Payload
Inspector fully visible while Claude responds. Continue manual navigation
through GGP's Enter submission so its deferred typing event cannot restart zoom.
All sessions must exist before capture; compact mode has no creation control.
The Watcher recorder prepares its fourth session before the Parallel chapter
begins, then reveals it with one real sidebar click after Custom nodes.
Finish GGP with one move to the inspector and keep typing-camera follow
suppressed through the result hold.

Parallel artwork stays still while branches finish and while it waits. When
every branch has finished and Combined is queued, one complete light pass
crosses it in four seconds.

After typing `hello graph` on the spoken send cue, keep its close-up for two
seconds before revealing the route and pressing Enter. Preserve the real edge
pulses and the single final move into the inspector.

Compute clearance for every pane subset, including tall inspector close-ups,
not only the full graph overview. Assert that each recorded framing leaves
Main View completely outside the viewport.
