# Power saving

- Graffitty does not prevent system sleep. Configure the host OS to stay awake for unattended remote access.
- Remote sessions pause while the host sleeps.
- Browser media playback can affect sleep.

## Rendering on battery

Add this to `~/.config/graffitty/client.toml`:

```toml
[power]
enabled = true
battery_world = "flat-2d"
external_world = "flat-3d"
```

This selects **Flat 2D on battery** and **Flat 3D on external power**, at startup
and whenever the power source changes. Either value can also be an installed world id, such as `"bistro"`, or a world path.
Running terminals survive the switch.

For startup selection only, disable following changes:

```toml
[power]
follow_changes = false
```

An explicit `--plugin` selection or restored session takes precedence at startup.
Unknown power state leaves the world unchanged. Manual world selections last
until the next power-source change (or recovery from an unknown state).
