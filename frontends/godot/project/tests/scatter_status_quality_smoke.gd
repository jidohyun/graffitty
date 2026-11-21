extends "scatter_color_smoke.gd"
## The transition card must retain native text/icon detail when magnified.
var mods: Node
var owner := Node.new()

## The pane-strip mod with a fixed sample, sized to its content.
func status(view: SubViewport) -> Control:
	if mods == null:
		var app := Node.new()
		app.name = "TerminalApplication"
		root.add_child(app)
		mods = load("res://scenes/mods/ModService.gd").new()
		mods.application = app
		app.add_child(mods)
		root.add_child(owner)
		var sample: Dictionary = mods.pane_resources({"status": "running", "cpu_valid": true, "cpu_percent": 0.0, "memory_current": 6291456}, "%15", 1)
		sample["agent"] = mods.agent_badge("codex", "idle", {}, [])
		mods.publish_pane(owner, "%15", sample)
	var strip: Control = mods.create_pane_strip(owner, "%15")
	view.add_child(strip)
	strip.render_now()
	strip.size = strip.get_combined_minimum_size()
	return strip

func run() -> void:
	for density in [1, 2]:
		var source := viewport(false)
		source.use_hdr_2d = true
		source.size_2d_override = Vector2i(288, 160)
		source.size_2d_override_stretch = true
		source.oversampling = true
		source.size = source.size_2d_override * density
		var original := status(source)
		original.scale = Vector2(2.5, 2.5)
		await snapshot(source, "live-%dx" % density)
		var captured := Pieces.capture_control(original)
		root.add_child(captured)
		check(captured.get_child(0).scale == Vector2.ONE, "Capturing compensated status text does not apply its sheet scale twice")
		var native := viewport(false)
		native.use_hdr_2d = true
		# The card is sized to its mod's content; the reference renders it at that size.
		native.size_2d_override = Vector2i(original.size)
		native.size_2d_override_stretch = true
		native.oversampling = true
		native.size = native.size_2d_override * density * 3
		status(native)
		check(captured.size == native.size, "Status capture retains %dx display density through 3x enlargement: %s" % [density, captured.size])
		var reference := await snapshot(native, "native-enlarged-%dx" % density)
		var texture := await snapshot(captured, "captured-enlarged-%dx" % density)
		if reference.get_size() == texture.get_size():
			# Compare text and icons, excluding viewport-edge panel antialiasing.
			var inset: Vector2i = Vector2i(6, 3) * density * 3
			var content := Rect2i(inset, reference.get_size() - inset * 2)
			compare(reference.get_region(content), texture.get_region(content), "Status text and icons at %dx DPI, enlarged 3x" % density)
		# The higher raster resolution must not change the card's UV/world size.
		var piece := Pieces.new()
		root.add_child(piece)
		var whole := Rect2(Vector2.ZERO, Vector2(captured.size_2d_override))
		piece.build_regions(captured, [whole], whole, Vector3.ZERO, Vector3.RIGHT, Vector3.DOWN, Vector2.ZERO, 0)
		check(piece._material().get_shader_parameter("cell_uv").is_equal_approx(Vector2.ONE), "High-DPI card keeps its logical size and full texture bounds")
		piece.queue_free()
		captured.queue_free()
		native.queue_free()
		source.queue_free()
	print("SCATTER_STATUS_QUALITY_PASS" if failures.is_empty() else "SCATTER_STATUS_QUALITY_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
