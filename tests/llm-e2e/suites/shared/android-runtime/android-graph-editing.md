# Android graph editing

Register two live node manifests through the CLI, connect their ports, compare the server graph, then disconnect without deleting nodes.

Register two fixture nodes, aim at the output socket, and double-tap-drag the centered cursor to the input. Require an authoritative server edge and unchanged terminal dimensions. RPC disconnect verifies subsequent synchronization; connection itself must use touch UI.

Adapted from `agent-graph/graph and disconnect-reroutes`. The shared implementation is `graph_editing` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-graph-editing --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-graph-editing --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
