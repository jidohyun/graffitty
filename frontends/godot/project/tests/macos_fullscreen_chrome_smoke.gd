extends SceneTree
var failures := 0
func _initialize() -> void:
	var scratch := OS.get_cache_dir().path_join("fullscreen-chrome-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, scratch.path_join(kind))
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	if DisplayServer.get_name() != "macOS":
		print("SKIP requires a native macOS window")
		quit()
		return
	root.extend_to_title = true
	root.size = Vector2i(900, 600)
	var background := ColorRect.new()
	background.color = Color("314351")
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bar: Control = load("res://scenes/TerminalTabBar.tscn").instantiate()
	root.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.tabs.title_formatter = func(item, _width): return item.title
	bar.present_tabs([{"id": 0, "title": "Fullscreen", "label": "Fullscreen"}], 0)
	await create_timer(0.5).timeout
	check(bar._title_margins.x > 0, "Windowed tab strip reserves native button space")
	root.mode = Window.MODE_FULLSCREEN
	await create_timer(1.5).timeout
	check(root.mode == Window.MODE_FULLSCREEN, "Window entered native fullscreen")
	check(bar._title_margins == Vector3.ZERO and bar.position.y == 0, "Fullscreen tab strip occupies the top with no native title inset")
	var image := root.get_texture().get_image()
	check(image.get_pixel(image.get_width() / 2, 1).get_luminance() > 0.01, "Fullscreen top edge contains the tab strip rather than a black gap")
	image.save_png("/tmp/graffitty-fullscreen-chrome.png")
	root.mode = Window.MODE_WINDOWED
	await create_timer(1.5).timeout
	check(bar._title_margins.x > 0, "Leaving fullscreen restores native button spacing")
	bar.free()
	background.free()
	print("MACOS_FULLSCREEN_CHROME_PASS" if failures == 0 else "MACOS_FULLSCREEN_CHROME_FAIL")
	quit.call_deferred(failures)
