# Local chromium shared GPU — MT-01

This is a strict requirement governed by [the suite contract](README.md).

## Verify native sharing and rendered chromium content

1. Start an isolated real session server and a separate production frontend on
   the same host, using a supported GPU-sharing configuration. Record both build
   identities, PIDs, frontend, OS, GPU and connection mechanism. Keep the user's
   existing server and workspace untouched.
2. Open a real chromium through the frontend. Use a local fixture page with four
   distinct colored regions, text input and a visibly increasing frame counter.
   Record the actual rendered frontend continuously. Type Unicode, scroll, and
   click a control; verify the resulting DOM state and visible updates.
3. Inspect the actual server-to-client transport. Require a native resource
   exchange and successful client GPU import, and correlate the imported texture
   and its dimensions/generation with rendered fixture content. A server capture
   label such as `captureTransport=iosurface` proves only capture, not client import.
4. For this chromium/session, require zero encoded JPEG/PNG/video frame payloads
   to this client and zero transport image/video encodes and decodes attributable
   to local presentation. Exclude the fixture's own web assets and unrelated
   remote subscribers from these counters; retain that scoping in the evidence.
   Renaming an encoded payload or uploading CPU-decoded pixels to the GPU fails.
5. Repeat with a frontend capable of hardware video decode. Video capability
   must not cause local presentation to choose HEVC/H.264/AV1 instead of shared
   GPU resources. Do not certify this from a synthetic Python client alone.

## Exercise resize, reconnect and resource lifetime

1. Resize the chromium repeatedly while it animates. Verify correct content and
   dimensions, a valid new resource generation, no stale frames and no import
   errors. Record imports/releases to establish that old handles are retired.
2. Disconnect the frontend without closing the server-owned chromium. Reattach a
   fresh frontend process; verify preserved DOM state, a fresh valid resource
   exchange and continuing animation without an encoded startup-frame fallback.
3. Close the chromium and frontend. Verify their imported resources are released
   and unrelated PTYs remain alive. Record the cleanup results.
4. Review the recording alongside the telemetry. Report PASS only when both
   visual behavior and verified shared GPU delivery satisfy every step.

JPEG/PNG compatibility delivery and video streaming fail this local case even if
they look correct or are fast. Unsupported native import belongs to MT-03 and
must not disguise missing support for a claimed supported local configuration.
Missing import/counter evidence is BLOCKED, not inferred success.
