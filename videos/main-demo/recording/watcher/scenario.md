# Watcher: new email → Claude → podcast

Keep this a short working example, not a code lecture. Follow the uppercase
chapter with the fourth prepared Bistro session. Use the current English UI,
normal-speed footage, narration voice, and continuous session transition.

1. **Watcher session clicked** — begin “This makes your graph pipeline versatile.
   For example, create a simple watcher node that triggers your agent when a
   condition is met.” during the sidebar transition. Show the minimal GGP source.
2. Run `uv run node.py email-cli wait` and frame both panes. **Watcher: connect**
   begins “Connect the watcher to Claude.” at the wire drag, with no preceding
   wait. Connect **Watcher / done → Claude / Receive** during that sentence.
   The external email command handles the condition; focus on GGP delivery.
3. Keep Claude's prepared conversation, but omit a separate readiness segment.
   **Watcher: result** begins “A new email arrives, and Claude makes a podcast
   just as it's told to!” when releasing the sample email. Retain the actual
   transfer and follow Claude's response. Claude announces new mail from Product Team,
   summarizes Friday's launch and Thursday's review deadline, and offers the
   created `inbox-podcast.wav`. Keep the ending readable without a long pause.

Do not narrate polling intervals, return codes, or a build job. No watcher code
underlines are needed. The preceding Payload Inspector introduction retains its
gold terminal box; the Watcher chapter uses Claude instead of an inspector.

The recorder uses `examples/watcher-node/node.py` unchanged, a local `email-cli`
fixture, and a prepared Claude playback scenario. It never contacts a real inbox
or a live Claude provider. GGP delivery and the podcast tool execution are real:
the tool validates the received email and creates playable audio with local TTS.
Record exactly one delivered receipt, preparation before arrival, silence before
arrival, and the podcast's duration as private evidence. Do not call a fixture
recording a live-provider or physical-device E2E pass.

Generate narration first so capture holds use measured durations. Run the
existing private-server recorder, then split and assemble all four node chapters:

```sh
python3 videos/main-demo/recording/watcher/record.py --output TAKE
python3 videos/main-demo/recording/node-sessions/split_take.py TAKE
python3 videos/main-demo/composition/append_watcher.py TAKE/watcher
```

Capture remains in the macOS background GPU guard and does not touch the user's
live sessions. Verify narration starts at the recorded click, before transition
completion, and verify real delivery and the playable artifact before export.
