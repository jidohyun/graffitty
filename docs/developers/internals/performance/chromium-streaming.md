# Chromium streaming

The server captures browser GPU frames, negotiates a supported codec, and streams
pages to clients. Control and input remain separate from video delivery.

## Follow the frame

1. The platform adapter captures a GPU surface.
2. The server chooses a compatible codec and rendition for each viewer.
3. Clients decode and present beneath the workspace canvas.
4. Resizing or recovery starts a new generation with a keyframe.

Capabilities are explicit: GPU, codec, platform, and client support determine the
available path. Browser video is not a terminal replication format.

## Key behavior

Hidden/paused panes avoid unnecessary work. Adaptive raster scale reduces video
cost without changing CSS layout. Slow viewers must not block healthy viewers.

See [platform stress](../chromium-platform-stress.md) for bounded performance and
failure evidence. The wire definitions, pause policy, transport details, and
recorded build checks are in the detailed record.

## Detailed evidence

[Chromium streaming — source notes and results](chromium-streaming-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
