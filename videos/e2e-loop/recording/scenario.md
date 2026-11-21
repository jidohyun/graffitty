Start a fresh isolated desktop session in the flat world at the desktop's
native UI scale. No speech and no captions.

Before recording, split the first pane right, move both panes outside Main View
(Claude left; Codex lower right, leaving room above it) and launch Claude and
Codex. Drag Claude's Turn completed to Codex's Receive (solid: every finished
build goes to Codex) and Codex's Send to Claude's Receive (dashed: Codex decides
to send). Frame both agents and the space above Codex.

The agents run on the movie clock, so their setup is recorded and then cut: Codex
is told “Test each build in Chromium and send failures to Claude.” and opens the
app with `gft chromium new --side above`, so its Chromium sits above it with an
ownership line; Claude is given “Build the sign-up page from spec.md”. The edit
starts at the "Loop start" beat, when Claude begins build 1.

The loop then runs by itself. Each build is real: Claude's build step publishes
it to the served app; Codex's `npm run e2e` drives the real Chromium through six
tests and prints each result; failures go to Claude through `graph.send` over the
dashed wire. Builds pass 1, 4, 5, 5 (a regression), then 6 of 6. After the
passing build Codex sends nothing and the loop stops. The camera holds the
overview throughout.

The edit dims the frame except a soft ellipse on the working side: Claude while
it implements, Codex and its Chromium while they test, fading between them. The
"Implement" sign shows the build; the "E2E Test" sign shows the run and its
result, kept up while Claude fixes it. The film loops: it starts and ends fully
lit. Agents are the dev mocks; no provider calls or accounts. Footage plays at 1×.
