extends "res://tests/unit/test_case.gd"
const Config := preload("res://graffitty/terminal_config.gd")
const Effects := preload("res://scenes/Effects.gd")

func test_default_enabled_and_explicit_off_survives_overlay() -> void:
    var config := Config.new()
    var effects := Effects.new()
    expect(effects.cursor_trail_settings().delay == 3, "Standalone worlds default to a trail")
    config.apply_effects(effects)
    expect(effects.cursor_trail_settings().style == "lightning" and effects.cursor_trail_settings().delay == 3, "Desktop and Android share the enabled Lightning default")
    config.effects.cursor_trail.delay_ms = 0
    var restored := Config.new()
    restored.overlay(config.to_config())
    restored.apply_effects(effects)
    expect(effects.cursor_trail_settings().delay == 0, "Explicit Off remains off after loading preferences")

func test_style_settings_round_trip_and_copy() -> void:
    var config := Config.new()
    config.effects.cursor_trail.style = "lightning"
    config.effects.cursor_trail.lightning.duration = 0.8
    config.effects.cursor_trail.lightning.glow_width = 12.0
    config.effects.cursor_trail.blaze.accent_color = Color.BLUE
    config.effects.typing_particles.preset = "glitter"
    var restored := Config.new()
    restored.overlay(config.to_config())
    expect(restored.validate().is_empty(), "Serialized settings remain valid")
    expect(restored.effects.typing_particles.preset == "glitter", "Particles round trip under terminal.effects")
    expect(restored.effects.cursor_trail.style == "lightning" and restored.effects.cursor_trail.lightning.duration == 0.8, "Style lifetime round trips")
    expect(restored.effects.cursor_trail.blaze.accent_color == Color.BLUE and restored.effects.cursor_trail.lightning.glow_width == 12.0, "Inactive and active style settings both survive")
    var copied = restored.copy()
    copied.effects.cursor_trail.lightning.glow_width = 2.0
    expect(restored.effects.cursor_trail.lightning.glow_width == 12.0, "World copies do not mutate user preferences")
    var effects := Effects.new()
    restored.apply_effects(effects)
    var settings = effects.cursor_trail_settings()
    expect(settings.style == "lightning" and settings.options.duration == 0.8 and settings.options.glow_width == 12.0, "World bridge receives selected style and style duration")
    restored.effects.cursor_trail.style = "invalid"
    expect(not restored.validate().is_empty(), "Unknown styles are rejected")

func test_both_renderers_stop_and_restart_on_movement() -> void:
    for path in ["res://scenes/CursorTrail.gd", "res://scenes/CursorTrail2D.gd"]:
        for style in ["smear", "blaze", "lightning"]:
            var trail = load(path).new()
            trail._ready()
            trail.configure(1, Vector2(.2, .8), Vector2.ZERO, Color.WHITE)
            expect(trail.decay == Vector2(.2, .8), "Smear preserves Kitty fast/slow times without scaling")
            trail.configure(1, Vector2(.1, .4), Vector2.ZERO, Color.WHITE, style, {"duration": .2})
            var project: Callable = func(uv): return Transform3D(Basis(), Vector3(uv.x, uv.y, 0))
            if trail is Node2D: project = func(uv): return uv * Vector2(800, 400)
            trail.update_cursor(Vector2i(1, 1), Vector2i(80, 24), .01, Vector2(10, 20), project)
            trail.update_cursor(Vector2i(20, 5), Vector2i(80, 24), .01, Vector2(10, 20), project)
            trail.update_cursor(Vector2i(20, 5), Vector2i(80, 24), .01, Vector2(10, 20), project)
            expect(trail.active, path + " " + style + " activates on cursor movement")
            trail.update_cursor(Vector2i(20, 5), Vector2i(80, 24), 2.0, Vector2(10, 20), project)
            expect(not trail.active and not trail._node.visible, "Effect ends " + style)
            trail.update_cursor(Vector2i(2, 7), Vector2i(80, 24), .01, Vector2(10, 20), project)
            trail.update_cursor(Vector2i(2, 7), Vector2i(80, 24), .01, Vector2(10, 20), project)
            expect(trail.active, "Expired " + style + " restarts")
            trail.free()
