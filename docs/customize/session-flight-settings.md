# Session flight settings

Tune the balance of letters and dust during a session transition. For the basic choices, see [Workspace appearance](world-settings.md#tab-and-session-transitions).

## Dust and flying characters

Session flights mix whole letters and dust. Denser tabs use fewer whole letters.

```toml
[worlds.flat-3d.session_switch]
fly_ratio_sparse = 0.5
fly_ratio_dense = 0.1
fly_dense_count = 1200
```

| Setting | Controls |
| --- | --- |
| `fly_ratio_sparse` | Whole-letter share in sparse tabs |
| `fly_ratio_dense` | Whole-letter share in dense tabs |
| `fly_dense_count` | Character count at which the dense ratio is reached |

Set both ratios to **0** for dust only, or **1** for whole letters only.

## In an effect preset

The example above is TOML for `client.toml`. A `.conf` effect preset loaded with
`--config=path/to/effects.conf` uses the following section instead:

```ini
[scene.session_switch]
effect = "fly_away_and_in"
fly_ratio_sparse = 0.5
fly_ratio_dense = 0.1
fly_dense_count = 1200
```
