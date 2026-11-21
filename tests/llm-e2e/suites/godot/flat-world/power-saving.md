# Power-aware world selection

Configure in `client.toml`:

```toml
[power]
enabled = true
battery_world = "flat-2d"
external_world = "flat-3d"
```

1. Start on battery: Flat 2D opens immediately.
2. Connect external power: Flat opens, preserving running terminals.
3. Disconnect external power: Flat 2D returns.
4. Manually select Flat while on battery. Repeated battery notifications must
   preserve that choice. An unknown power source must also preserve it.
5. Recover a known battery state: Flat 2D returns.
6. Open another window. It uses the same power source, and both windows respond
   to the next change. Close the second window and change power again safely.
7. With `follow_changes = false` under `[power]`, startup uses the power source
   but subsequent changes leave that window alone.

The replay injects power events so these checks do not require changing the
machine's power supply. Native subscriptions require platform smoke testing.
