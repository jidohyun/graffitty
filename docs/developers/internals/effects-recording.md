# Record a terminal effect

Record the real app with `videos/effects/recording/record.py`.
Use a new output directory for each take.

## Prepare

You need Godot 4.7 with the built native extension and imported assets,
a working GPU/display, Podman, FFmpeg with `libsvtav1`, and FFprobe.
Run the app once before recording. Headless rendering cannot record these effects.

## Record one effect

From the repository root:

```sh
videos/effects/recording/record.py --list
videos/effects/recording/record.py --effect particles-sparks --build-image \
  --backend movie --fps 60 --resolution 1280x800 --output shots/sparks-take-1
```

The recorder creates an isolated shell and waits until it is ready.
It does not send input to your existing sessions.

## Review the take

1. Open the output directory's `index.html` and play the entire clip.
2. Check `effect.mp4` and `preview.png` for framing and visible typing.
3. Inspect `probe.json` and the Godot log for encoding or runtime errors.
4. Keep failed-take evidence; choose a new directory for the next take.

Videos have no audio. The `movie` backend uses fixed simulation steps;
`live` captures real-time frames and includes readback overhead.
Neither is a GPU benchmark.

## Other recording tasks

| Task | Reference |
| --- | --- |
| Record all effects or adjust encoding | [Backends and options](effects-recording-reference.md#the-two-backends) |
| Record workspace interaction | [Tiling demo](effects-recording-reference.md#tiling-window-demo) |
| Send scripted terminal input | [Virtual input](effects-recording-reference.md#virtual-input-with-gft) |
| Update the effects gallery | [Gallery design](effects-recording-reference.md#gallery-design) |
| Choose export locations | [Video destinations](effects-recording-reference.md#video-export-destinations) |
