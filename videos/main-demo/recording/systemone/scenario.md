# SystemOne: choose the right agent

Append after Android; it opens the graph chapters and leads into Parallel. Use the same desktop graph backdrop and window framing,
normal-speed 60 fps recording, keyboard effects, narration voice, chapter heading
and subtitles. Keep the chapter short: it shows one prompt being routed.

Everything is prepared off camera: Claude and Codex mocks are running, and
Manual Prompt and SystemOne are launched in their panes. The recording shell maps
SystemOne to `gft dev systemone-mock`, which shares the production form and graph
runtime; only its Decisions responses are scripted. SystemOne starts from saved
settings (choice mode, a short routing question, Claude and Codex outputs, `.text`
as the Decisions input), so its two output ports already exist. The node panes are
renamed `Manual Prompt` and `SystemOne JEV`, and Manual Prompt → SystemOne JEV →
Claude/Codex are wired through the real ports. All three routing connections are
solid: submitting Manual Prompt emits directly, and SystemOne automatically sends
to its selected destination.

The chapter opens on the connected graph with the narration: “Graph is very useful
when you want to quickly prototype a pipeline. This SystemOne node that calls the
JEV decision model in the middle will route the session for you based on your
question!” The camera moves in on the `SystemOne JEV` pane when the second sentence
begins. Then type “What does HTTP 429 mean?” into Manual Prompt and submit it. Show
JEV route it to Claude while Codex stays idle, and end on Claude's short reply.
Preserve real input delivery, queue acknowledgements and graph status; do not
simulate wiring or terminal UI. Verify the three routing edges, the JEV pane title,
and the delivered prompt in Claude's actual mock session transcript.

Rebuild from the repository root (use a fresh take directory). The recorder reads
the `systemone-intro` voice's duration and word timings from `demo-audio.json`, so
regenerate that line first whenever its text changes:

```sh
cargo build -p graffitty-cli --bin gft
python3 videos/shared/typing/build.py
python3 videos/main-demo/composition/generate_narration.py --line systemone-intro
python3 videos/main-demo/recording/systemone/record.py --output videos/main-demo/assets/takes/systemone-demo/final
python3 videos/main-demo/composition/append_systemone.py videos/main-demo/assets/takes/systemone-demo/final
```

Then, in `videos/main-demo/composition`, run `python3 music.py --prepare`,
`bun run check`, `python3 refresh_nodes.py`, and `python3 verify_delivery.py`.
The node renderer copies the desktop's compressed video frames, reuses unchanged
node chapter encodes, and produces one WebM. The mock transcript and graph verification
are saved in the take beside the raw footage.
