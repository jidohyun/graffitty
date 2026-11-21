Start a fresh isolated desktop session. Show two Claude workers and one Codex
worker in a left column, a real `gft node parallel` in the middle, and a Claude
reviewer on the right. Prepare the panes and launch commands before recording,
with floating pane physics enabled. Start on the complete unconnected 3–1–1
layout, then show actual port drags and focused prompt typing.
Keep the default typing effects enabled and type through real keyboard events.
Let setup effects settle before recording begins so wire sockets stay steady.
Make the Parallel pane about 1100×1150 with a 24px terminal font, centered beside
the three workers, so its progress and input list remain readable in the overview.
Give the reviewer a top-aligned 1200×1150 pane with the same 24px font, so its
review reads beside Parallel without a close-up.

Connect each worker's Turn completed to Parallel's Join, then Combined to the
reviewer's Receive. Make these port drags brisk, then hold the completed graph
for two seconds so viewers can understand the wiring. Prepare the reviewer first with:
“Graffitty will send you combined implementation of three different specs. Once you receive, review which is the best”
Wait for its Ready response. Enter “Implement with spec A”, B, and C in their
respective workers. Zoom into each worker while typing and hold its close-up for
1.5 seconds afterward. Keep the typing effect active for four seconds after input
so it stays engaged between prompts instead of repeatedly zooming out and in.
Return to the workers and Parallel together after the last close-up.
Keep all three busy concurrently; finish them at staggered
times so the Parallel progress is readable. Show that the reviewer stays idle
for the first two completions and receives exactly one combined payload only
after the third. The reviewer reads all three real session file references,
compares the implementations, and selects spec B. End on the connected graph.
Record at 60 fps. No user account or real provider calls. All agent processes use
the existing dev mock machinery; Parallel uses the production command.

While responses arrive, frame the three workers plus Parallel. Do not cut to
Parallel plus reviewer after the first two completions. Follow the combined
handoff into that 1–1 view as the last worker starts its final response.

Parallel’s Combined output is automatic after every input arrives, so its wire must be solid. Dashed wires indicate a later agent decision. Verify the real manifest and all four rendered wire styles in the capture.

In the main demo this chapter follows SystemOne: it opens on the sidebar click into the Parallel session, which arrives with all three workers running and the solid wires already connected. The narration starts on that click. Omit wiring and prompt entry. Use only: “The parallel node waits until every agent finishes. Once all three finish, it sends their results and session references together to the reviewer.” End after the combined handoff narration. Keep retained footage at 1×.

Append the reviewed running-agent section with
`python3 videos/main-demo/composition/append_parallel.py <take> --start-frame <frame>`.
The `solid-output` take starts at frame 2360. The end is derived from the combined
handoff cue plus the two-sentence narration, retaining every selected frame at 60 fps.
