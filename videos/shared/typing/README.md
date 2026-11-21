# Human typing for the demo

Source: Vivek Dhakal, Anna Feit, Per Ola Kristensson, and Antti Oulasvirta,
*Observations on Typing from 136 Million Keystrokes*, CHI 2018.
https://userinterfaces.aalto.fi/136Mkeystrokes/
DOI: 10.1145/3173574.3174220

The publisher permits research and non-commercial use with attribution.
The original README is preserved beside the compressed archive. This attribution
and restriction also accompany the timing data derived here.

`../datasets/Keystrokes.zip` is DVC-tracked without unpacking it. `build.py` reads
participant files directly from the ZIP into memory, using a seeded sample of
correct sentences typed at 60–145 WPM. It excludes corrections, invalid timestamps,
and long interruptions. It retains no participant identities or sentence text.

`model.json` keeps observed press-to-press intervals, keyboard transition groups,
and complete internal timing traces for words used in the demo. `timings.json`
contains four reproducible 60 fps schedules for each exact phrase in `phrases.json`.
Recordings alternate these variants when a phrase repeats. Whole-word samples
retain real timing correlations; unknown words use observed letter-pair timings,
falling back to keyboard transition groups with correlated variation. Command
cadence is sped up by 1/0.72 and prose by 1/0.88 for an experienced demo typist;
intervals are quantized to 2–30 frames. These are synthesized schedules based on
human data, not recordings of someone typing these exact commands.

To add or revise a phrase, edit `phrases.json` and run:

```sh
python3 videos/shared/typing/build.py
python3 -m unittest discover -s videos/shared/typing -p 'test_*.py'
```

That uses only the small model. No ZIP download, decompression, or corpus scan is
needed again. Only to rebuild the empirical model itself:

```sh
python3 videos/shared/typing/build.py --archive videos/shared/datasets/Keystrokes.zip
```

The archive SHA-256, sampling criteria, and counts are recorded in the model.
Capture metadata records the schedule hash and actual key frames for verification.
Only the demo's recording scripts use this helper; interactive terminal input and
E2E replay defaults retain their original behavior. Held Vim navigation keys use
regular autorepeat, rather than simulated prose typing. The MarkdownPreview
command retains its separate two-second pause and camera hold before Enter.

Parallel demo-agent scenarios set `scenario_clock` to advance their work and output on
that capture clock. Encoder speed therefore cannot finish a worker while the
recording is still typing another worker’s prompt. Normal mock runs without a
capture clock continue to use wall time.
