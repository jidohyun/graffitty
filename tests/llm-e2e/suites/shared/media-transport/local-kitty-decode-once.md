# Local Kitty images decode once — MT-02

This is a strict requirement governed by [the suite contract](README.md).

## Verify live image delivery without client PNG decoding

1. Start an isolated real server, PTY and separate production frontend on the
   same host. Record build identities and the negotiated image transport. Record
   the actual frontend throughout the case.
2. Generate a fresh PNG fixture with known RGBA pixels, transparency and distinct
   colored regions. Use a unique fixture per run to avoid a prewarmed decode cache
   hiding work. Record its dimensions and source/decoded-pixel hashes.
3. Emit a real Kitty inline PNG upload from the PTY with an explicit image ID and
   placement. Observe the image in the terminal and inspect per-image counters:
   exactly one server PNG decode and zero client PNG decodes for that upload.
4. Require delivery of server-decoded pixels through shared memory or IPC. Verify
   the client's imported/mapped/received pixel hash and dimensions against the
   fixture, as well as the visible placement and transparency. No image, an empty
   payload, or an alleged shared-memory reference without actual mapping fails.
   PNG (`f=100`) replay to the local client fails even if a decoder cache avoids
   work on a later attempt. Sending decoded raw Kitty pixels over IPC is allowed;
   sharing a GPU texture is not required for this image case.
5. Repeat with a new fixture via a server-side temporary-file Kitty upload. Verify
   the server consumes/deletes the source and that the frontend does not reopen
   its path. Use a second attached client: both must render the same image without
   another PNG decode or independently resolving a server path.

## Verify reconnect, replacement and cleanup

1. After the source file is gone, detach the frontend and start a fresh process.
   Reattach to the same PTY. Require identical pixels and placement, no repeated
   server decode for the retained image, and zero client PNG decodes.
2. Replace the same image ID with a fresh fixture. Verify new pixels replace the
   old pixels on both clients, with one decode for the new upload and no stale
   shared-memory generation. Delete the image through Kitty and verify it vanishes.
3. Close clients and the test PTY. Verify handles/mappings and server image storage
   are released when no longer referenced, without affecting unrelated sessions.
4. Review the recording and scoped decode/mapping evidence for every step. Report
   PASS only when real frontend rendering and the decode-once transport both pass.

The repository-root `tests/support/local_media_e2e.py --case kitty --evidence NEW_DIRECTORY`
can diagnose live/reconnect PNG replay. It is supporting evidence, not an LLM run,
and currently does not cover actual GUI rendering or SHM lifetime.
