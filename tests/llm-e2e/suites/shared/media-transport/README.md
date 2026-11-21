# Mandatory media transport requirements

These LLM E2E cases are the normative acceptance requirements for media delivery.
They apply to the shipping Godot app and to any frontend that replaces it.
Moving or replacing a frontend must preserve these cases and their requirements.
Prototype results cannot certify a shipping frontend that was not exercised.

| Requirement | LLM E2E case |
| --- | --- |
| MT-01: Local chromium presentation uses verified shared GPU resources, not encoded frame delivery | [local-chromium-shared-gpu](local-chromium-shared-gpu.md) |
| MT-02: Local Kitty images use server-decoded pixels through SHM or IPC, without another client PNG decode | [local-kitty-decode-once](local-kitty-decode-once.md) |
| MT-03: Sharing is established by native resource import, never hostname or socket type | [tunneled-media-capabilities](tunneled-media-capabilities.md) |

These are strict requirements, not performance suggestions. A refactor, frontend
replacement, transport change, or release touching these paths is not accepted
until the applicable cases pass. They must not be weakened or deleted merely to
make a replay pass. Missing native sharing on a supported same-host configuration
is FAIL, not a successful fallback. An actual unsupported import must negotiate
the portable path explicitly, as MT-03 specifies.

An LLM must run the production frontend, review the recorded behavior, inspect
the transport evidence and issue a verdict for each frontend/platform/connection
combination. Visible correctness alone cannot prove the transport. A codec label,
source-code inspection or a script's exit code alone cannot prove the behavior.
Absent telemetry or unavailable hardware is BLOCKED with a reason, never PASS;
an observed forbidden path or missing implementation is FAIL. BLOCKED does not
satisfy the requirement. Unexpected dialogs and engine errors fail the run.

Preserve build identities, connection topology, supported/negotiated mechanisms,
import outcomes, scoped encode/decode counters, recordings, and cleanup evidence.
Do not store credentials in the evidence. Report unsupported combinations
explicitly rather than silently dropping them from the matrix.

`tests/support/local_media_e2e.py` at repository root is a supporting diagnostic only.
It currently exposes JPEG/HEVC and Kitty PNG fallback through private IPC; it
does not run a GUI, prove GPU import or exercise SSH. Its existence, deletion,
replacement or eventual success cannot replace these LLM E2E requirements.
The initial diagnostic observations are FAIL, not completed LLM E2E runs.
