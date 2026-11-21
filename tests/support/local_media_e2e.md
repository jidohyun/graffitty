# Local media transport acceptance tests

Build the shared owner, then run from the repository root:

```sh
cargo build -p graffitty-cli --locked
python3 tests/support/local_media_e2e.py --evidence /tmp/local-media-run
```

The evidence directory must be new. `--server PATH` selects a frozen binary;
`--case kitty` runs without Chromium or a GPU. Chromium cases currently require
macOS Metal, Clang, the bundled chromium-video libraries, and the native CEF host
(`dist/chromium-host-path.txt` or `GRAFFITTY_CHROMIUM_HOST`). Missing prerequisites,
timeouts, and absent media fail the test.

Each case starts and stops its own private owner. Evidence includes the owner
binary hash, packet headers and payload hashes, logs, and cleanup records. Chromium
checks compile the production Mach/Metal transport into a native probe loaded in
the IPC client's process. Its source hash is retained alongside GPU samples. No
GUI frontend is substituted for this transport-level probe.

## Required behavior

| Case | Acceptance |
| --- | --- |
| Chromium, default client | Transfer a native IOSurface right and sample a known two-color texture on Metal |
| Chromium, video-capable client | Prefer the verified GPU resource path locally; no encoded chromium packets |
| Chromium resize and reconnect | New dimensions, old imported resources remain valid, fresh connection-bound proof required |
| Chromium GPU import failure | Reject native mode; hardware-decode fallback video and verify actual pixels |
| Chromium destination released | Detect the dead native endpoint, notify the client, and resume decodable video |
| Chromium through a separate Unix byte relay | Kernel peer mismatch rejects native sharing; video still decodes correctly |
| Kitty live file upload | Server consumes/deletes the source; client requests and receives the exact image asset and placement |
| Kitty reconnect after source deletion | Server scene preserves image assets and placement without reopening the source |
| Kitty multipart upload and reconnect | Chunk boundaries cannot leak image escapes into scene text |

Chromium fixtures use black and white regions to verify spatially distinct GPU
samples without display color profiles changing expected RGB values. Resizing
also verifies the old resource was not reused in place. Local PNG/JPEG delivery
does not satisfy these chromium checks; portable fallback is encoded video.
Kitty checks use a known 2×2 RGBA fixture and image ID 9001. Packet boundaries and
Kitty chunk boundaries are independent. Scene text contains no image escapes;
placement metadata identifies demand-fetched PNG or RGBA assets. This fixture
uses portable asset packets and makes no shared-memory claim.

## Locality is a negotiated capability

Neither loopback TCP nor a Unix socket establishes shared GPU access: either can
be forwarded. The macOS fast path requires:

1. An authenticated chromium session and explicit `mach-iosurface-v1` offer.
2. A real IOSurface transferred through a native Mach right, never a serialized
   handle number or a server filesystem path.
3. Import of a fresh random probe on the renderer's Metal device. A GPU blit reads
   its challenge, and a native reply transfers proof to the owner.
4. Kernel audit identities matching the Unix peer PID in both directions. A
   separate byte-forwarding process cannot satisfy that binding.
5. A new exchange on reconnect, a five-second proof deadline, bounded native
   queues, resource release, and portable fallback after exchange/import failure.

The chromium transport does not require shared-memory Kitty mapping. That remains
an independent optional capability; this suite verifies portable scene asset packets.
Linux/Windows native GPU exchange and actual cross-host GPU compatibility are not
covered by these macOS tests. GUI frontend composition, zero-copy rendering, and
performance require their separate frontend/benchmark checks. The native probe
performs GPU readback for verification; normal chromium delivery only imports the
immutable texture and does not use that readback path.
