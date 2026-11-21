# Chromium streaming implementation record

Recorded evidence; these results apply to the named runs and artifacts.

## Scope

This record describes streaming mechanisms and dated measurements. Current
capability/protocol definitions remain the shared source of truth; obsolete
pre-negotiation formats are not alternate supported contracts.

## Pause and raster policy

Offscreen or <96 physical-pixel pages report height 0, retain topology/input,
and stop frame delivery. Initially tiny panes pause immediately; displayed ones
wait 0.5 s and resume at 128 px. Paused panes consume no video budget. Capture
stops when all viewers pause, including shared local GPU viewers.

The largest viewer determines raster demand. On macOS scale is tier/CSS height,
clamped 1/8–1; unknown demand retains CSS resolution. Device emulation changes
raster/capture, not CSS layout/DPR. Retain idle surfaces for late viewers/keyframes.

## Encoding and recovery

Packets identify codec, epoch, sequence, keyframe, and dimensions; payloads are
complete access units with configuration in keyframes. Video profile: 8-bit 4:2:0,
no B-frames, target 60 FPS subject to source updates.
Capture/encoding runs outside input/session loops; raw capture retains newest state.
Reference packets remain ordered. Reset requests keyframes; decoder rejection
removes that codec for the connection and renegotiates independently of terminal input.
PNG is an explicit advertised preview; required-video clients fail with no common codec.

ACK window starts at four, grows toward RTT×60+2 (max16) below 25 ms queueing,
and shrinks by a quarter per RTT above 60 ms. Four fixed credits limited a 130 ms
link to ~26 FPS. Slow clients cannot force unbounded storage.

## GPU ownership and control

Copy borrowed IOSurfaces once into immutable owned storage, retain through
VideoToolbox encoding, and release Mach rights correctly after failed sends.
No PNG/JPEG/CPU conversion occurs in the hardware encoder path. This is not
end-to-end zero-copy: the recorded remote Godot path still uploaded decoded pixels.

Private CDP sockets use event-driven GCD reads; median server→page input changed
15→5 ms from the old 20 ms tick. Image readback/compression uses a separate worker.
No public debug listener or image-capture CDP escape is opened.

## Video datagrams beside the WebSocket

Only encrypted OPAQUE logins with `video-datagram-v1` receive an offer containing
UDP port/ssrc. Local capability logins receive no unencrypted datagram path.
Hello/reply confirmation establishes the path/NAT state; three seconds without
hellos returns video to WebSocket. Switching restarts recovery state.
The WebSocket retains login, control, terminal traffic, ACKs, loss/keyframe/codec messages.
Reassembly/loss handling runs on a worker. The “WebSocket video” warning explains
missing offer, socket failure, no reply, or stopped replies.

## Presentation and recorded measurements

Pages composite beneath the workspace canvas; a pane hole and sheet shader preserve
later overlays. SM-T733 at 1440p/HEVC: canvas 30 vs beneath-canvas 37 page FPS;
frame draw 21.5→11.7 ms, world pass ~14 ms remained dominant. These are specific runs.

## Input and menus

Chrome macOS uses native finger/momentum phases, accumulated subpixel deltas, and
eventTime spacing. Alloy's windowless wheel API uses synthetic phases and stops at edges.
CEF context menus preserve IDs/state/submenus and return selection/dismissal;
remote request tokens route to the originating viewer, not the hidden host window.
Website handlers can suppress the default menu.

## Build and validation

Build static pinned FFmpeg with `tools/build_chromium_video.py`, then the CEF host,
server, and extension. The low-delay patch waits for asynchronous no-B-frame output.
Recorded M1 Max HEVC/H.264, desktop/emulator HEVC, physical tablet decode/scroll,
multi-client/resize/recovery/rejection/preview checks passed in their environments.
Those runs did not exercise AV1 hardware or Windows/Linux hardware backends.
