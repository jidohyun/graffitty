extends "effects-pixels.gd"

func inverse_ray(fraction: Vector2) -> Vector2:
	# Independent ray/plane intersection and tangent-coordinate solve, without
	# calling the application's sheet_point_at inverse.
	var world: Node = host.world
	var u: Vector3 = world.uv_du
	var v: Vector3 = world.uv_dv
	var origin: Vector3 = world.uv_origin
	var ray: Vector3 = world.proj_forward + world.proj_right * (world.proj_rect.x + fraction.x * world.proj_rect.z) + world.proj_up * (world.proj_rect.y + (1 - fraction.y) * world.proj_rect.w)
	var hit: Variant = Plane(origin, origin + u, origin + v).intersects_ray(world.proj_eye, ray)
	if hit == null: return Vector2.INF
	var d: Vector3 = hit - origin
	var determinant := u.dot(u) * v.dot(v) - u.dot(v) * u.dot(v)
	return Vector2((d.dot(u) * v.dot(v) - d.dot(v) * u.dot(v)) / determinant, (d.dot(v) * u.dot(u) - d.dot(u) * u.dot(v)) / determinant) * world._sheet_size()

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Camera raw reader starts in original PTY"): return
	var dialog := await open_settings()
	dialog.trail.select(0)
	dialog.particles.select(0)
	dialog.fields.intensity.text = ".5"
	dialog.fields.maximum.text = "2"
	dialog.fields.enter.text = ".1"
	dialog.fields.hold.text = ".6"
	dialog.fields.leave.text = ".25"
	dialog.fields.pane.text = "1"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Effects applied to this window.", "Configured typing camera applied through dialog")
	overlay.hide()
	capture("effects-dialog")
	var scroll: ScrollContainer = dialog.grid.get_parent()
	scroll.scroll_vertical = int(dialog.grid.size.y)
	await process_frame
	capture("effects-dialog-bottom")
	dialog.canceled.emit()
	await process_frame
	var flatten: Callable = host.effect_control.hold(["sheet.ripple", "sheet.curvature"])
	if not await command("\u001b[2J\u001b[2 q\u001b[2;3HTyping camera acceptance\u001b[11;31H", Vector2i(30, 10)): return
	await hold(1.5)
	var view: Control = host.workspace_view
	var local: Vector2 = terminal.position + Vector2.ONE * float(terminal.cell_padding) + (Vector2(terminal.get_cursor_cell()) + Vector2(.5,.5)) * terminal.get_cell_size()
	var canvas: Vector2 = view.terminal_origin(host.pane_focus) + local * view.terminal_scale(host.pane_focus)
	var baseline: Vector2 = host.world.sheet_window_fraction(canvas)
	var trace: Array = []
	var maximum := 0.0
	await press_key(KEY_X, 120)
	var deadline := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var fraction: Vector2 = host.world.sheet_window_fraction(canvas)
		var error := inverse_ray(fraction).distance_to(canvas)
		maximum = maxf(maximum, error)
		trace.append({"zoom":host.world.fx_cam_zoom,"error_pixels":error,"fraction":[fraction.x,fraction.y]})
	capture("typing-configured-peak")
	check(absf(host.world.fx_cam_zoom - 1.5) < .02, "Configured 50 percent intensity reaches actual 1.5 camera zoom")
	check(maximum < .75, "Independent camera ray recovers unchanged caret within 0.75 pixels")
	await hold(1.5)
	capture("typing-configured-after")
	check(absf(host.world.fx_cam_zoom - 1.0) < .01 and (host.world.sheet_window_fraction(canvas) - baseline).length() * view.size.x < 2, "Configured hold and decay restore original view")
	FileAccess.open(directory.path_join("typing-projection.json"), FileAccess.WRITE).store_string(JSON.stringify({"samples":trace,"maximum_error_pixels":maximum}, "  "))
	flatten.call()
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Camera probe records input"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "x", "Camera controls inject no extra PTY input")
	check(terminal.get_shell_pid() == pid, "Configured camera preserves original shell PID")
