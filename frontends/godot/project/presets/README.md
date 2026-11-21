# Built-in world defaults

These `.conf` files are renderer resources bundled with worlds. User settings
and named profiles belong in `client.toml`; see [appearance settings](../../../../docs/customize/configuration-appearance.md).

## Configure effects

```toml
[effects.camera]
zoom = 1.2
tilt_limit_deg = 5

[effects.sheet]
ripple = 0.5

[effects.splash]
scale = 2.5
```

Use the [effects gallery](../../../../docs/customize/effects.md) to preview and copy settings.
World authors can load an internal resource with `TerminalEffectsSettings`.
