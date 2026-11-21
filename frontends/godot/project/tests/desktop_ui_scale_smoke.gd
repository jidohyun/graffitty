extends SceneTree
## One configured display, no terminal server. Pass -- --expect-ui-scale=1.5.

func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var expected := 0.0
	var text_scale := 1.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expect-text-scale="): text_scale = float(arg.get_slice("=", 1))
		if arg.begins_with("--expect-ui-scale="): expected = float(arg.get_slice("=", 1))
	if expected <= 0.0 or DisplayServer.get_name() == "headless":
		printerr("Use a windowed display and --expect-ui-scale=<number>")
		quit(2)
		return
	var app := root.get_node("TerminalApplication")
	app.configure_window_scale(root)
	var detached := Window.new()
	detached.hide()
	detached.force_native = true
	detached.gui_embed_subwindows = true
	detached.current_screen = root.current_screen
	root.add_child(detached)
	detached.show()
	app.configure_window_scale(detached)
	var bar := preload("res://scenes/TerminalTabBar.tscn").instantiate()
	detached.add_child(bar)
	var embedded := AcceptDialog.new()
	detached.add_child(embedded)
	embedded.popup_centered()
	await create_timer(0.5).timeout
	var ok := embedded.is_embedded() and is_equal_approx(embedded.content_scale_factor, 1.0)
	ok = ok and embedded.get_ok_button().get_theme_font_size("font_size") == roundi(20 * text_scale)
	var tab_size: int = bar.tabs.get_theme_font_size("font_size", "TerminalTab")
	ok = ok and tab_size == roundi(14 * text_scale)
	for window in [root, detached]:
		ok = ok and not window.is_embedded() and is_equal_approx(window.content_scale_factor, expected)
		ok = ok and window.get_final_transform().get_scale().is_equal_approx(Vector2.ONE * expected)
	print("%s scale: root=%s detached=%s embedded=%s expected=%s tab_font=%s" % [
		DisplayServer.get_name(), root.content_scale_factor, detached.content_scale_factor,
		embedded.content_scale_factor, expected, tab_size])
	if "--check-monitor-moves" in OS.get_cmdline_user_args():
		embedded.hide()
		var moved := await check_monitor_moves(detached, expected)
		ok = ok and moved
	detached.queue_free()
	quit(0 if ok else 1)

## Run in automatic mode on a Windows desktop with two different display scales.
func check_monitor_moves(detached: Window, root_scale: float) -> bool:
	if DisplayServer.get_name() != "Windows": return false
	var mixed := false
	var original := root.current_screen
	for screen in DisplayServer.get_screen_count():
		var expected := DisplayServer.screen_get_dpi(screen) / 96.0
		if is_equal_approx(expected, root_scale): continue
		var target := DisplayServer.screen_get_usable_rect(screen)
		detached.size = Vector2i(480, 300)
		detached.position = target.get_center() - detached.size / 2
		await create_timer(0.5).timeout
		if not is_equal_approx(detached.content_scale_factor, expected): return false
		if not is_equal_approx(root.content_scale_factor, root_scale): return false
		mixed = true
	detached.position = DisplayServer.screen_get_usable_rect(original).get_center() - detached.size / 2
	await create_timer(0.5).timeout
	if not mixed: printerr("Two Windows monitors with different effective DPI are required")
	return mixed and is_equal_approx(detached.content_scale_factor, root_scale)
