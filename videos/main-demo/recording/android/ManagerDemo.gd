extends "AndroidDemo.gd"
## A reusable opening: the production server chooser, then a real connection.
func run() -> void:
	Input.emulate_mouse_from_touch = true
	get_node("/root/Localization").set_language("en-US", false)
	root.size = Vector2i(1968, 1968)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 2.625
	# Use the current saved-connection schema, even when reusing a take directory.
	assert(preload("res://scenes/remote/ClientAuthentication.gd")._save([]).is_empty())
	manager = preload("res://scenes/remote_manager.tscn").instantiate()
	add_child(manager)
	await wait(.5)
	var choices: Array = JSON.parse_string(FileAccess.get_file_as_string(data_path("manager-settings.json")))
	var first := ""
	for choice in choices:
		var key: String = manager._remember_entry(choice, "disconnected", "Ready to connect")
		manager.session_passwords[key] = str(choice.token)
		if first.is_empty(): first = key
		# Learn and cache the OS through real authentication before recording.
		# Never guess it from a display name or paint an icon onto the footage.
		var transport: Node = manager.open_connection(choice)
		if not await until(func(): return transport.connected and not str(manager.entries[key].get("platform", "")).is_empty(), "Saved server learns its OS through authentication", 60.0):
			quit(1)
			return
		manager._disconnect(key)
		manager._set_state(key, "disconnected", "Ready to connect")
	manager._show_chooser()
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	contacts = Fingers.new()
	contacts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(contacts)
	contacts.size = root.get_visible_rect().size
	await wait(.5)
	expect(manager.entries.size() == 2 and manager.chooser.visible, "Show two saved computers before opening a workspace")
	var audio: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(data_path("demo-audio.json")))
	var intro_duration := 0.0
	for voice in audio.voices:
		if voice.id == "android-intro": intro_duration = float(voice.duration_s)
	assert(intro_duration > 0)
	var writer = Engine.get_singleton("GraffittyMovieWriter")
	writer.set_recording(true)
	var recording_start_frame := int(writer.frames_written())
	started = demo_ticks_msec()
	beat("Android: workspace manager")
	var cards: Array = manager.cards.values()
	expect(cards[1].global_position.y >= cards[0].global_position.y + cards[0].size.y,
		"Workspace manager shows compact stacked server cards")
	expect(manager.brand.is_visible_in_tree(), "Centered Graffitty logo is visible")
	expect(manager.connection_tab.is_visible_in_tree() and manager.settings_tab.is_visible_in_tree(),
		"Sticky Connection and Settings navigation is visible")
	for card in cards:
		expect(card.os_icon.texture == manager.ServerCard._icon("os-macos"), "Saved Mac displays authenticated macOS artwork")
		expect(not card.address.text.begins_with("ws://"), "Server address omits the WebSocket scheme")
		expect(card.status.global_position.y > card.heading.global_position.y and card.address.global_position.y > card.status.global_position.y,
			"Three-line card shows hostname, status, then address")
	# Match the accepted connection cue, keeping every later chapter in place.
	var post_narration_frames := 38
	while writer.frames_written() - recording_start_frame < ceili(intro_duration * 60.0) + post_narration_frames:
		await get_tree().process_frame
	await get_tree().process_frame
	root.get_texture().get_image().save_png(data_path("manager.png"))
	beat("Android: connect chosen workspace")
	var connect_at := point(manager.cards[first].select)
	emit_touch(0, true, connect_at)
	await wait(.12)
	# Capture the button press, then settle the connected UI off the movie clock.
	writer.set_recording(false)
	emit_touch(0, false, connect_at)
	# Connection waits use wall time while the movie clock is paused.
	var movie_started := started
	started = 0
	if not await until(func(): return (manager.view.host != null and manager.touch_start.available
		and not manager.view.host.sessions.is_empty()), "Chosen computer connects and enables Touch to start", 60.0):
		quit(1)
		return
	started = movie_started
	writer.set_recording(true)
	await wait(.35)
	beat("Android: open connected workspace")
	await tap(manager.brand)
	if not await until(func(): return not manager.chooser.visible, "Touch to start opens the connected workspace"):
		quit(1)
		return
	writer.set_recording(false)
	host = manager.view.host
	view = host.workspace_view
	await wait(.5)
	terminal().send_text("clear\r")
	await wait(.5)
	expect(root.size == Vector2i(1968, 1968), "Connecting preserves the Android window dimensions")
	expect(root.get_texture().get_image().get_size() == Vector2i(1968, 1968), "Connected viewport fits the fixed capture without clipping")
	writer.set_recording(true)
	beat("Android: workspace connected")
	expect(view.tab_bar._title_margins == Vector3.ZERO, "Mobile tab strip reserves no desktop window-button space")
	await wait(.2)
	root.get_texture().get_image().save_png(data_path("connected.png"))
	beat("Android: manager intro complete")
	quit(0 if failures.is_empty() else 1)
