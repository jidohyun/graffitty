# Implement → E2E → fix loop

Claude implements a sign-up page. Codex tests every build in its own Chromium
and sends the failures back, until all six E2E tests pass. No speech: a
spotlight follows the working side and two signs ("Implement", "E2E Test") show
each build and its result. See [recording/scenario.md](recording/scenario.md).

```sh
# 1. Record a take (agents are scripted mocks; builds, browser and tests are real).
cp target/release/gft /tmp/gft-snapshot
GRAFFITTY_TEST_SERVER=/tmp/gft-snapshot \
  python3 videos/e2e-loop/recording/record.py --output videos/e2e-loop/assets/takes/<name>

# 2. Build the HyperFrames edit from it, check, and render.
cd videos/e2e-loop/composition
python3 prepare.py ../assets/takes/<name>
bunx hyperframes@0.9.59 check
python3 ../../shared/render.py --project . --format mp4 --fps 60 --quality delivery
```

The render goes to `videos/artifacts/e2e-loop/e2e-loop.mp4`; graffitty.com's
`scripts/screenshots.py` derives the website hero video from it. Each take keeps
`results-N.json` and `sent-N.json` for every build, and `record.py` fails unless
they match `expected.json`.

| File | Role |
| --- | --- |
| `recording/fixtures.py` | The five builds and both mock agent scripts |
| `recording/tools.py` | Real side effects: publish a build, open Chromium, run E2E, send feedback |
| `recording/LoopDemo.gd` | The replay: layout, wiring, loop beats, checks |
| `composition/prepare.py` | Trims the take to the loop and writes the HyperFrames edit |
