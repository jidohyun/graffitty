# Agents and attention sounds

Open **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Agents**, or run `:Agents` from the prefix command line.

See Claude, Codex, Pi and OpenCode across connected servers and sessions.

## Priority and connected panes

| Group | Meaning |
| --- | --- |
| Pinned | Agents you want to keep at the top |
| Needs you | Waiting for input or reporting an error |
| Done | Completed work you have not viewed |
| Working | Running a turn |
| Idle | Ready for more work |

- Hover an agent to pin it.
- Connected browsers, terminals and agents appear below their agent.
- Drag the panel title to move or dock it.

## Client-only sound configuration

In `client.toml`:

```toml
[sounds]
enabled = true
blocked = "" # Needs input or reports an error.
done = ""    # Finished outside the focused view.
```

- Empty paths use the bundled sound.
- Custom sounds: Ogg Vorbis, MP3 or WAV, up to ten seconds.
- Relative paths start in this client's configuration directory.
- Missing or unsupported files fall back to the bundled sound.
- Restart the client after changing the file.

**View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Agent sounds** toggles playback until restart. Android uses media volume.
