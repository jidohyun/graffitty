extends "res://llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
## A product demonstration using the same real input path as the E2E replays.
var output := ""
var demo_directory := "/Users/Shared/demo-workspace/demo"
var capture_active := false
var beats: Array[Dictionary] = []
var peak_typing := 0.0
var settling: Array[Dictionary] = []
var castle_surfaces: Array[String] = []


func point_at(target: Vector2, seconds := 0.7) -> void:
	await super.point_at(target, seconds * 0.4)


func wait(seconds: float) -> void:
	await super.wait(seconds * 0.45)


func camera_at_rest(seconds := 8.0) -> void:
	var start: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	await super.camera_at_rest(seconds)
	var end: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	if capture_active and end - start > 84:
		settling.append({"start_frame": start, "end_frame": end})


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-output="):
			output = arg.trim_prefix("--demo-output=")
		if arg.begins_with("--demo-directory="):
			demo_directory = arg.trim_prefix("--demo-directory=")
	super._initialize()
	# The app's automatic language follows the host's system locale and
	# overrides Godot's --language. Save English in the replay's private config
	# before the Localization autoload reads it, then confirm it took effect.
	root.get_node("Localization").set_language("en-US")
	require_english.call_deferred()
	# The replay base selects its own isolated config directory. Install the
	# Castle preset there before its deferred host startup reads world settings.
	if OS.get_cmdline_user_args().has("--plugin=edinburgh-castle"):
		var config := preload("res://config/UserConfig.gd").config_path()
		DirAccess.make_dir_recursive_absolute(config.get_base_dir())
		DirAccess.copy_absolute("res://videos/main-demo/recording/tiling/castle-client.toml", config)
	process_frame.connect(publish_animation_clock)


## Runs before the replay overlay exists, so it cannot use check()'s toast.
func require_english() -> void:
	var english := TranslationServer.get_locale() == "en_US"
	print("[demo] ", "PASS" if english else "FAIL", " The demo records the English interface")
	if not english: failures.append("The demo records the English interface")


func publish_animation_clock() -> void:
	var path := output.path_join("animation-clock")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(str(Engine.get_singleton("GraffittyMovieWriter").frames_written() * 1000 / 60))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)


func say(step: String) -> void:
	print("[demo] ", step)
	var frame: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	beats.append({"frame": frame, "seconds": frame / 60.0, "action": step})


func shell_text(key: String) -> String:
	var result := ""
	for cell in host.sessions[int(key.substr(1))].term.cell_glyphs():
		result += String.chr(int(cell.cp))
	return result


func ready_shell(key: String) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while not "TILING_READY" in shell_text(key) and Time.get_ticks_msec() < deadline:
		await process_frame
	check("TILING_READY" in shell_text(key), "The isolated demo shell is ready")


func command(text: String) -> void:
	for ch in text:
		_send_key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0), {})
		await hold(0.025)
		peak_typing = maxf(peak_typing, host.world.fx_typing)
	_send_key(KEY_ENTER, 0, {})
	await say("Typing finished")
	await hold(0.3)


func snapshot(name: String) -> void:
	var expected := {"01-one-pane": "LiveTerminalWall1", "05-filetree-open": "Royal Palace", "12-markdown-preview": "National War Museum"}
	if expected.has(name):
		check(str(host.world.surfaces[host.world.active].id) == expected[name], "Visible Castle surface at " + name + ": " + str(host.world.surfaces[host.world.active].id))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))


func until(predicate: Callable, description: String, timeout := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	var passed: bool = predicate.call()
	check(passed, description)
	if not passed:
		await snapshot("failed-" + str(beats.size()))
		for id in host.sessions:
			print("[demo terminal %", id, "] ", shell_text("%%%d" % id))
	return passed


func file_point(key: String, filename: String) -> Vector2:
	var terminal: Node = host.sessions[int(key.substr(1))].term
	var rows := {}
	for glyph in terminal.cell_glyphs():
		var line: String = rows.get(int(glyph.row), "")
		while line.length() <= int(glyph.col): line += " "
		line[int(glyph.col)] = String.chr(int(glyph.cp))
		rows[int(glyph.row)] = line
	for row in rows:
		var col: int = rows[row].find(filename)
		if col >= 0:
			var pane: Control = host.workspace_view.panes[key]
			var local: Vector2 = terminal.position + Vector2(col + 2.5, row + 0.5) * terminal.get_cell_size()
			return host.workspace_view.window_point(pane.body.get_global_transform() * local)
	check(false, "Filename is visible for mouse input: " + filename)
	return Vector2.ZERO


func open_file_with_mouse(key: String, filename: String) -> void:
	var point := file_point(key, filename)
	await point_at(point)
	tap()
	await process_frame
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	event.double_click = true
	event.position = point
	event.global_position = point
	root.push_input(event, true)
	await release(MOUSE_BUTTON_LEFT, 0.0)
	await hold(0.3)


func enlarge_image(chromium_key: String) -> void:
	var view: Control = host.workspace_view
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var old_height: float = view.pane_rects[chromium_key].size.y
	for divider in Layout.tile_dividers(tree.tiles, view.content_rect()):
		if divider.axis != "v": continue
		var point: Vector2 = divider.rect.position + divider.rect.size * Vector2(0.65, 0.5)
		var destination := Vector2(point.x, view.content_rect().end.y - 110)
		await say("Enlarge the image pane")
		await point_at(view.window_point(point), 0.2)
		await press()
		await point_at(view.window_point(destination), 0.45)
		await release()
		await hold(0.2)
		check(view.pane_rects[chromium_key].size.y > old_height * 1.4,
			"Dragging the divider makes the PNG viewer substantially larger")
		return
	check(false, "The image viewer has a draggable divider")


func hold_full_view() -> Dictionary:
	var cfg = host.world.fx_cfg
	var active: String = str(cfg.behavior.active_state)
	var frame: Dictionary = cfg.frame(active)
	var saved := {"state": active, "camera.zoom": frame["camera.zoom"],
		"camera.tilt_limit_deg": frame["camera.tilt_limit_deg"], "pane_zoom": cfg.typing_settings().pane_zoom}
	cfg.set_option("state." + active, "camera.zoom", 1.0)
	cfg.set_option("state." + active, "camera.tilt_limit_deg", 0.0)
	cfg.set_option("scene.typing", "pane_zoom", 1.0)
	host.workspace_view._reset_pane_zoom()
	return saved


func restore_full_view(saved: Dictionary) -> void:
	var cfg = host.world.fx_cfg
	for key in ["camera.zoom", "camera.tilt_limit_deg"]:
		cfg.set_option("state." + str(saved.state), key, saved[key])
	cfg.set_option("scene.typing", "pane_zoom", saved.pane_zoom)


func filetree_demo(old_panes: Array) -> void:
	var view: Control = host.workspace_view
	var original_count: int = host.sessions.size()
	var original_pids := {}
	for key in old_panes:
		original_pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
	FileAccess.open(output.path_join("host-mode"), FileAccess.WRITE).close()
	await say("Create a second tab for filetree")
	await click(on(tab_strip().plus))
	if not await until(func(): return host.sessions.size() == original_count + 1,
		"A fresh terminal opens in the second tab"): return
	var source := ""
	for id in host.sessions:
		var candidate := "%%%d" % id
		if candidate not in old_panes: source = candidate
	if not await until(func(): return host.pane_focus == source, "The new tab receives focus"): return
	await ready_shell(source)
	await camera_at_rest()
	check(host.workspace_layout.tabs.size() == 2, "The first tab is preserved beside the filetree tab")
	await hold(0.4)
	await say("Chapter: filetree")
	await point_at(await on_header(source, "filetree"), 1.0)
	await hold(0.25)
	await press()
	await release()
	if not await until(func(): return host.sessions.size() == original_count + 2, "Filetree opens beside its shell"): return
	var tree: String = host.pane_focus
	check(tree != source, "Clicking the icon focuses the filetree")
	if not await until(func(): return "README.md" in shell_text(tree), "Prepared filetree opens", 30.0): return
	check(host.application.notifications.history.is_empty(), "Prepared filetree opens without a setup warning")
	await say("Filetree ready")
	await hold(0.4)
	await snapshot("05-filetree-open")
	await say("Filetree: follow the shell cwd")
	var saved_effects := hold_full_view()
	await say("Cwd effects disabled")
	await click(on(view.panes[source].handle))
	await command("cd docs")
	if not await until(func(): return "notes.txt" in shell_text(tree), "Changing the shell cwd expands docs in the filetree"): return
	check(str(host.sessions[int(source.substr(1))].term.get_ui_state().get("cwd", "")).ends_with("/demo/docs"),
		"The shell reports its actual new cwd")
	await hold(0.3)
	await snapshot("06a-filetree-cwd-docs")
	await command("cd ..")
	if not await until(func(): return "notes.txt" not in shell_text(tree), "Returning to the project collapses docs"): return
	await hold(0.3)
	await snapshot("06b-filetree-cwd-collapsed")
	await command("cd ..")
	if not await until(func(): return "demo" in shell_text(tree) and "README.md" not in shell_text(tree), "Moving above the project changes the filetree root to its parent"): return
	await hold(0.3)
	await snapshot("06c-filetree-cwd-parent")
	await command("cd demo")
	if not await until(func(): return "README.md" in shell_text(tree), "Returning to the project expands its folder under the new root"): return
	check(is_equal_approx(host.world.fx_cam_zoom, 1.0) and host.world.fx_cam_tilt.length() < 0.001,
		"Camera zoom and tilt remain off during cwd navigation")
	check(is_equal_approx(host.world.fx_cfg.typing_settings().pane_zoom, 1.0),
		"Pane zoom remains off during cwd navigation")
	await say("Cwd view settled")
	await hold(0.3)
	await snapshot("06-filetree-cwd")
	await say("Chapter: filetree: edit filenames like a vim buffer")
	await open_file_with_mouse(tree, "docs")
	if not await until(func(): return "notes.txt" in shell_text(tree), "Mouse opens docs for editing"): return
	await click(file_point(tree, "notes.txt"))
	restore_full_view(saved_effects)
	# The click leaves the cursor inside the stem, so ciw replaces just "notes".
	await type("ciw")
	for ch in "plan":
		_send_key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0), {})
		await hold(0.15)
	await keys("escape")
	await hold(0.3)
	await type(":w{enter}")
	await hold(0.4)
	await snapshot("07-filetree-rename-pending")
	if not await until(func(): return "Want to continue?" in shell_text(tree), "Fyler previews the filename change"): return
	await keys("enter")
	if not await until(func(): return FileAccess.file_exists(demo_directory.path_join("docs/plan.txt")), "Vim buffer write renames the actual file", 8.0): return
	check(not FileAccess.file_exists(demo_directory.path_join("docs/notes.txt")), "The original filename is gone")
	await hold(0.5)
	await snapshot("08-filetree-renamed")
	await camera_at_rest()
	if "--filetree-only" in OS.get_cmdline_user_args():
		beats.clear()
		capture_active = true
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await say("Chapter: filetree: open text files in nvim, and image/pdf in chromium")
	await open_file_with_mouse(tree, "plan.txt")
	if not await until(func(): return host.sessions.size() == original_count + 3, "Text file opens in connected Neovim"): return
	var editor := ""
	for id in host.sessions:
		var candidate := "%%%d" % id
		if candidate != source and candidate != tree and candidate not in old_panes: editor = candidate
	if not await until(func(): return "Keep related work together." in shell_text(editor), "Neovim displays the text file"): return
	host.focus_pane(editor)
	await say("Text viewer ready")
	await hold(2.0)
	await snapshot("09-filetree-text")
	check(host.pane_focus == editor, "Neovim has keyboard focus without moving the pointer")
	await say("Quit Neovim with :q")
	await type(":q")
	await snapshot("09-filetree-quit")
	await keys("enter")
	if not await until(func(): return not view.panes.has(editor), "Neovim exits through :q"): return
	check(not is_instance_valid(host.close_dialog) or not host.close_dialog.visible,
		"Quitting Neovim does not show a close-pane dialog")
	await say("Text viewer closed")
	await camera_at_rest()
	await say("Text viewer transition settled")
	await hold(0.65)
	await point_at(file_point(tree, "layout.png"), 1.75)
	await hold(0.3)
	await open_file_with_mouse(tree, "layout.png")
	if not await until(func(): return host.chromiums.size() == 1, "PNG opens in Chromium", 40.0): return
	var chromium: Node = host.chromiums.values()[0]
	if not await until(func(): return chromium.texture != null, "Chromium renders the image", 30.0): return
	var decoded := false
	var deadline := Time.get_ticks_msec() + 10000
	while not decoded and Time.get_ticks_msec() < deadline:
		var loaded: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
			"expression": "location.href.endsWith('/docs/layout.png') && document.images[0]?.complete && document.images[0]?.naturalWidth === 640",
			"returnByValue": true}})
		decoded = loaded.get("result", {}).get("result", {}).get("value", false) == true
		if not decoded: await process_frame
	check(decoded, "Chromium decodes the actual demo PNG")
	await say("Image viewer ready")
	await snapshot("10-filetree-image")
	await hold(0.7)
	var chromium_key: String = "%%%d" % host.chromiums.keys()[0]
	await enlarge_image(chromium_key)
	await hold(0.4)
	check(host.world.fx_typing < 0.01, "Mouse-driven file opening and resizing leave typing effects idle")
	await snapshot("11-filetree-image-large")
	await point_at(root.get_visible_rect().size * Vector2(0.92, 0.91), 0.4)
	await hold(0.35)
	for key in old_panes:
		check(host.sessions.has(int(key.substr(1)))
			and host.sessions[int(key.substr(1))].term.get_shell_pid() == original_pids[key],
			"The original tiling shell stays alive in the first tab")
	check(host.workspace_layout.tabs.size() == 2, "Filetree demonstration remains in the second tab")


func rearrange(source: String, target: String, edge: String) -> void:
	var view: Control = host.workspace_view
	await say("Rearrange " + source + " to the " + edge + " of " + target)
	var rect: Rect2 = view.pane_rects[target]
	var point := rect.position + rect.size * Vector2(0.5, 0.5)
	if edge == "bottom": point.y = rect.end.y - 40
	if edge == "right": point.x = rect.end.x - 40
	await point_at(on(view.panes[source].handle), 0.7)
	await press()
	await point_at(view.window_point(point), 1.25)
	await hold(0.25)
	check(view.layout_preview.visible, "Dragging previews the resulting tiles")
	check(view.preview_plan.get("edge", "") == edge, "The intended split edge is selected")
	await release()
	await camera_at_rest()
	check_tiles()
	check(not view.overview, "Rearranging stays in Main View")
	await hold(0.35)


func play() -> void:
	var places: Array = host.world.surfaces.duplicate()
	places.append_array(host.world.spare_places)
	places.sort_custom(func(a, b): return int(a.get_meta("place")) < int(b.get_meta("place")))
	for i in mini(3, places.size()): castle_surfaces.append(str(places[i].id))
	if not check(host.world.settings.surface_order.is_empty(), "Live Castle uses the default surface order"): return
	if not check(castle_surfaces == ["LiveTerminalWall1", "Royal Palace", "National War Museum"], "Live Castle allocation: " + str(castle_surfaces)): return
	host.world.terminal_config.background.alpha = 0.5
	host.world._apply_terminal_config()
	# Preview only: retain Flat's exact effect configuration in the Castle world.
	host.world.fx_cfg = host.world.Effects.new()
	host.world.fx_cfg.load_config("res://presets/flat.conf")
	host.world.terminal_config.apply_effects(host.world.fx_cfg)
	preload("res://scenes/FlatWorldSettings.gd").new().apply_effects(host.world.fx_cfg)
	host.world.fx_cfg.set_option("scene.sheet", "corner_radius", 0.0)
	host.world.fx_cfg.set_option("scene.sheet", "edge_blur", 0.0)
	host.world.default_config = "res://presets/flat.conf"
	host.world._fx_apply_scene()
	host.world.terminal_effects.configure(host.world.fx_cfg)
	if host.world.get("weather") != null: host.world.weather.set_weather("none")
	# Use the desktop DPI policy so the recorded chrome has native proportions.
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = maxf(1.0, DisplayServer.screen_get_scale(root.current_screen))
	root.size = Vector2i(2400, 1500)
	await hold(0.3)
	var previous := overlay
	overlay = load("res://videos/shared/TilingPointer.gd").new()
	previous.get_parent().add_child(overlay)
	previous.queue_free()
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	await ready_shell(first)
	check(host.world.default_config == "res://presets/flat.conf",
		"The demo uses the bundled Flat effects preset")
	check(host.world.fx_enabled and host.world.fx_cfg.frame("typing")["typing.particles"] == "sparks",
		"Default typing sparks are enabled")
	var defaults := preload("res://graffitty/terminal_config.gd").new()
	var actual = host.world.terminal_config
	check(actual.background.color == defaults.background.color
		and is_equal_approx(actual.background.alpha, 0.5)
		and actual.font_family == defaults.font_family and actual.font_size == defaults.font_size,
		"Terminal uses demo opacity 0.5 with the same font and colors")
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		await view_menu("Tiling")
	view.show_main()
	await type("git log --oneline -3{enter}")
	await super.camera_at_rest()
	await hold(0.5)
	overlay.pointer = root.get_visible_rect().size * Vector2(0.72, 0.83)
	await RenderingServer.frame_post_draw
	var canvas := root.get_texture().get_image().get_size()
	check(canvas == Vector2i(2400, 1500), "Movie canvas fits the native UI: %s" % canvas)
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	if "--chromium-only" in OS.get_cmdline_user_args():
		await load("res://videos/main-demo/recording/tiling/ChromiumChapters.gd").new(self).play()
		return
	if "--filetree-only" in OS.get_cmdline_user_args():
		capture_active = false
		Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
		await filetree_demo([first])
		await say("Finished")
		return
	await say("One terminal in Main View")
	await hold(0.4)
	await snapshot("01-one-pane")
	await say("Create a pane to the right")
	var second := await add_window(first, "h")
	if second.is_empty(): return
	await ready_shell(second)
	await say("Create a pane below")
	var third := await add_window(second, "v")
	if third.is_empty(): return
	await ready_shell(third)
	await say("Type in the last pane")
	await command("git status --short")
	# Demonstrate dragging immediately, while the typing effect settles.
	await owner_at_rest()
	await snapshot("02-three-panes")
	var pids := {}
	for key in [first, second, third]:
		pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
	await rearrange(third, first, "bottom")
	await snapshot("03-first-shuffle")
	for key in pids:
		check(host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key],
			"The same shell survives the layout change")
		check(view.panes[key].handle.text.ends_with("/demo"),
			"The default pane title uses the demo working directory")
	check(host.workspace_layout.tabs.size() == 1 and view.panes.size() == 3,
		"Three distinct terminals remain in one tab")
	check(peak_typing > 0.5, "Simulated typing activates the default effects")
	await point_at(root.get_visible_rect().size * Vector2(0.91, 0.89), 0.6)
	await hold(0.3)
	await filetree_demo([third, second, first])
	await load("res://videos/main-demo/recording/tiling/ChromiumChapters.gd").new(self).play()


func finish() -> void:
	Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	capture_active = false
	var captured_frames: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	var file := FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"fps": 60, "frames": captured_frames,
		"beats": beats, "settling": settling, "failures": failures, "size": [2400, 1500],
		"ui_scale": root.content_scale_factor,
		"terminal_config": "app defaults", "effects_preset": host.world.default_config,
		"peak_typing": peak_typing, "castle_surfaces": castle_surfaces}, "\t"))
	file.close()
	super.finish()
