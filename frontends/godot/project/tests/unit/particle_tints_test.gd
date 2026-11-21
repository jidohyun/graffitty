extends "res://tests/unit/test_case.gd"
const Tints := preload("res://scenes/ParticleTints.gd")

func particle(id: int, text: String, cell := Vector2i(4, 0)) -> Dictionary:
	return {"kind": "sparks", "unicode": text.unicode_at(0), "age": 0.6,
		"tint_source": {"id": id, "cell": cell, "unicode": text.unicode_at(0)}}

func glyph(text: String, col: int, color: Color, row := 0, wide := false) -> Dictionary:
	return {"cp": text.unicode_at(0), "col": col, "row": row, "foreground": color, "wide": wide}

func test_quick_keys_with_shared_stale_cursor_keep_distinct_colors() -> void:
	var a := particle(1, "a")
	var b := particle(2, "b")
	Tints.refresh([a, a, b], [glyph("x", 4, Color.WHITE), glyph("a", 5, Color.RED), glyph("b", 6, Color.BLUE)], 80)
	expect(a.tint_source.get("foreground") == Color.RED, "First burst finds its rendered glyph despite a stale cursor")
	expect(b.tint_source.get("foreground") == Color.BLUE, "Second burst retains its own color")

func test_repeated_keys_are_matched_in_order_and_late_highlighting_updates() -> void:
	var a := particle(1, "a")
	var b := particle(2, "a")
	Tints.refresh([a, b], [glyph("a", 4, Color.WHITE), glyph("a", 5, Color.WHITE)], 80)
	Tints.refresh([a, b], [glyph("a", 4, Color.RED), glyph("a", 5, Color.BLUE)], 80)
	expect(a.tint_source.get("foreground") == Color.RED, "Particles older than 300 ms still receive highlighting")
	expect(b.tint_source.get("foreground") == Color.BLUE, "Repeated letters resolve to different cells")

func test_single_mismatch_does_not_borrow_neighbor_color() -> void:
	var a := particle(1, "a")
	Tints.refresh([a], [glyph("x", 4, Color.WHITE), glyph("a", 5, Color.RED)], 80)
	expect(not a.tint_source.has("foreground"), "A lone unmatched key cannot steal a neighboring color")

func test_resolved_bursts_do_not_move_to_a_different_word() -> void:
	var a := particle(1, "a")
	var b := particle(2, "b")
	Tints.refresh([a, b], [glyph("a", 4, Color.RED), glyph("b", 5, Color.RED)], 80)
	Tints.refresh([a, b], [glyph("x", 4, Color.WHITE), glyph("a", 5, Color.BLUE), glyph("b", 6, Color.BLUE)], 80)
	expect(a.tint_source.foreground == Color.RED and b.tint_source.foreground == Color.RED,
		"Replacing text cannot redirect existing bursts to a nearby matching word")

func test_wide_character_run_wraps_to_next_row() -> void:
	var a := particle(1, "한", Vector2i(6, 0))
	var b := particle(2, "b", Vector2i(6, 0))
	Tints.refresh([a, b], [glyph("한", 6, Color.RED, 0, true), glyph("b", 0, Color.BLUE, 1)], 8)
	expect(a.tint_source.get("foreground") == Color.RED, "Wide glyph retains its color")
	expect(b.tint_source.get("foreground") == Color.BLUE, "Next glyph resolves across wrapping")

func test_both_particle_renderers_apply_recoloring() -> void:
	for script in [preload("res://scenes/TerminalParticles.gd"), preload("res://scenes/TerminalParticles2D.gd")]:
		var pool = script.new()
		pool.source_cell = Vector2i(4, 0)
		pool.source_unicode = 97
		pool.tint_source = {"id": 1, "cell": Vector2i(4, 0), "unicode": 97}
		var p: Dictionary = pool.make_particle("sparks", Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3.BACK)
		p.age = 0.6
		p.hue = 0.0
		p.brightness = 1.0
		pool.sparks.append(p)
		pool.refresh_tints([glyph("a", 4, Color.RED)], 80)
		expect(p.color.is_equal_approx(Color.RED), "Live particles recolor in both 2D and 3D")
		pool.free()

func test_deletion_samples_both_halves_of_wide_glyphs() -> void:
	var glyphs := [glyph("a", 2, Color.BLUE), glyph("한", 3, Color.RED, 0, true), glyph("b", 5, Color.GREEN)]
	expect(Tints.glyph_at(glyphs, Vector2i(2, 0)).foreground == Color.BLUE, "English backspace keeps its color")
	expect(Tints.glyph_at(glyphs, Vector2i(4, 0)).foreground == Color.RED, "Backspace after Korean samples its leading glyph")
	expect(Tints.glyph_at(glyphs, Vector2i(3, 0)).foreground == Color.RED, "Forward Delete on Korean samples the same color")
	expect(Tints.glyph_at(glyphs, Vector2i(5, 0)).foreground == Color.GREEN, "Wide glyph does not steal the next character")
	expect(Tints.glyph_at(glyphs, Vector2i(4, 1)).is_empty(), "Another row cannot provide a deletion color")

class DeletionTerminal extends Node:
	func get_grid_size() -> Vector2i:
		return Vector2i(80, 24)
	func get_write_color() -> Color:
		return Color.WHITE
	func cell_glyphs() -> Array:
		return [{"row": 0, "col": 3, "wide": true, "foreground": Color.RED}]

class DeletionEffects3D extends "res://scenes/TerminalEffects.gd":
	func pulse(_uv: Vector2) -> void:
		pass

class DeletionEffects2D extends "res://scenes/TerminalEffects2D.gd":
	func pulse(_uv: Vector2) -> void:
		pass

func test_both_effect_handlers_capture_korean_deletion_color() -> void:
	for effect in [DeletionEffects3D.new(), DeletionEffects2D.new()]:
		effect.terminal = DeletionTerminal.new()
		effect.particles = effect.Particles.new()
		for event in [[Vector2i(5, 0), 8], [Vector2i(3, 0), 127]]:
			effect._on_keystroke(event[0], event[1])
			expect(effect.particles.text_color == Color.RED, "Both renderers snapshot Korean color before deletion")
			expect(effect.particles.source_cell == Vector2i(3, 0), "Deletion burst belongs to the leading glyph cell")
			expect(effect.particles.source_unicode == 0, "Deleted glyph color is not resampled after removal")
		effect.terminal.free()
		effect.particles.free()
		effect.free()
