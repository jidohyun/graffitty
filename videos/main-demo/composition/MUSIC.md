# Background music

The user supplied `Audiio_Ben-Laver_Sonder_Keeper_Instrumental.wav` from Downloads.
The original file is preserved in `assets/music/` (the composition's assets symlink
points into `../assets/composition`). Source WAV, normalized FLAC, and frozen
processed FLAC are all tracked by `../assets.dvc`. Provenance and the source SHA256
are in `music.json`.

The bed follows the film duration, including the final SystemOne chapter. A two-second
crossfade repeats an earlier passage before the source track ends to extend the
original instrumental, then rejoins the remaining source. The mix has a
1.5-second fade in and a 5-second fade out. Source gain is -10 dB.
HyperFrames' voiceover analysis at strength 0.65 creates five dynamic peaking
filters plus a level envelope against all narration clips.
`music-profile.json` preserves that analysis. The Web Audio bake
applies the filters and interpolates their dB envelopes at 10 ms intervals.
The profile follows the current narration cues and preserves the source audio.

`assets/music/bed.flac` is the frozen stereo result, already carved and faded.
The HTML and FFmpeg exports both consume this exact file at unity gain; do not
apply the profile again on playback. The narration remains a separate track.
The single WebM delivery uses stereo Opus at 128 kbps.

To rebuild the bed after changing the narration or film duration, run from this
composition directory (Chrome, FFmpeg, and the HyperFrames audio skill required):

```sh
npm ci --prefix music-tools
python3 music.py --prepare
bun run check
python3 music.py --refresh
python3 verify_delivery.py
```

`--carve-script /path/to/hyperframes-audio/scripts/carve.mjs` overrides the skill
location. The helper packages have their own lockfile; the composition renderer
remains pinned to 0.8.168. The checked-in frozen profile and bed also allow normal
renders without installing the analysis tools.

`--refresh` remixes from lossless audio masters and stream-copies the existing
WebM video. It compares compressed video SHA256 before replacing the canonical
export. It replaces `main-demo.webm` in place after
validation; temporary files are consumed by that replacement. Do not create
versioned or change-specific filenames for subsequent revisions.
Future full renders and chapter exports use the same bed; chapter offsets select
the corresponding music segment. Export fails if narration cues have changed
without rebuilding the music profile.

When node footage or subtitles also change, use `python3 refresh_nodes.py`
instead of `--refresh`. It copies the desktop's compressed frames and renders
only Android, Parallel, and SystemOne directly to WebM, reusing unchanged chapter
encodes on reruns. It does not recapture Chromium or make an MP4 delivery.

After rebuilding, run `dvc add videos/main-demo/assets` from the repo root.
