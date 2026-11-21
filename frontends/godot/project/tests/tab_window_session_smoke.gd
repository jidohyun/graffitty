extends "res://tests/terminal_space_smoke.gd"
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
var pointer_position := Vector2.INF
var app: Node

func _initialize() -> void:
	Background.install(self)
	super._initialize()

func settled(host: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	await process_frame
	while is_instance_valid(host) and (not host.session_backend.connection.connected or host.session_backend.work_pending()) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(.15).timeout

func input_roundtrip(host: Node, id: int, label: String) -> void:
	var terminal: Control = host.sessions[id].term
	# The marker appears only in the shell's output, not in the echoed command.
	var marker := 'MOVE_OK_%d' % Time.get_ticks_msec()
	if OS.get_name() == "Windows":
		terminal.send_text("Write-Output ('MOVE_' + '" + marker.trim_prefix('MOVE_') + "')\r")
	else:
		terminal.send_text("printf 'MOVE_%s\\n' '" + marker.trim_prefix('MOVE_') + "'\n")
	var deadline := Time.get_ticks_msec() + 15000
	while marker not in str(terminal.get_text(false).get('text', '')).replace('\n', '') and Time.get_ticks_msec() < deadline:
		await process_frame
	var received := str(terminal.get_text(false).get('text', '')).replace('\n', '')
	if marker not in received:
		print("INPUT_ROUNDTRIP ", JSON.stringify({"pane": id, "active_tab": host.workspace_layout.active, "focused": host.pane_focus, "text": received}))
	check(marker in received, label)

func start_drag(host: Node) -> Vector2:
	var strip: Control = host.workspace_view.tab_bar.tabs
	var deadline := Time.get_ticks_msec() + 2000
	while strip._settling and Time.get_ticks_msec() < deadline: await process_frame
	var button: Button = strip.buttons[host.workspace_layout.active]
	var point: Vector2 = button.global_position + Vector2(40, button.size.y * .5)
	# Canceling with Escape leaves the physical button held until its release.
	var up := InputEventMouseButton.new()
	up.position = point
	up.button_index = MOUSE_BUTTON_LEFT
	host.get_window().push_input(up, true)
	pointer_position = app.screen_point(host.get_window(), point)
	var press := InputEventMouseButton.new()
	press.position = point
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	host.get_window().push_input(press, true)
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(12, 0)
	motion.relative = Vector2(12, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer_position += Vector2(12, 0)
	host.get_window().push_input(motion, true)
	return pointer_position

func move_drag(point: Vector2) -> void:
	var window: Window = app.drag.source.get_window()
	var motion := InputEventMouseMotion.new()
	motion.position = window.get_screen_transform().affine_inverse() * (point - Vector2(window.position))
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	window.push_input(motion, true)

func end_drag(point: Vector2) -> void:
	var window: Window = app.drag.source.get_window()
	var release := InputEventMouseButton.new()
	release.position = window.get_screen_transform().affine_inverse() * (point - Vector2(window.position))
	release.button_index = MOUSE_BUTTON_LEFT
	window.push_input(release, true)
	await process_frame

func run() -> void:
	var wrapper: Node = load('res://scenes/terminal.tscn').instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if not check_host(wrapper): return
	var first: Node = wrapper.host
	app = first.application
	app.scripted_pointer = true
	await settled(first)
	check(wrapper.connection.workspace == '$1', 'Ordinary launch creates session $1')
	var pane: int = first.active_session_id
	var pid: int = first.sessions[pane].term.get_shell_pid()
	var identity := root.get_window_id()
	var origin := root.position
	var pointer := await start_drag(first)
	check(not app.drag.is_empty() and app.drag.get('window_drag', false), 'Dragging the sole tab starts a whole-window move')
	pointer_position = pointer + Vector2(80, 65)
	move_drag(pointer_position)
	check(root.position != origin and root.get_window_id() == identity, 'The original window moves before release')
	check(app.drag_preview == null and app.hosts.size() == 1, 'No detached preview or replacement window appears')
	await end_drag(pointer_position)
	check(first.sessions[pane].term.get_shell_pid() == pid and wrapper.connection.workspace == '$1', 'Window movement preserves its shell and session')
	var created: Dictionary = await wrapper.connection.request_action('create', {'kind':'tab'})
	await wrapper.connection.request_action('sync')
	await settled(first)
	var tab := int(created.created)
	await start_drag(first)
	var outside := Vector2(root.position + Vector2i(root.size.x + 160, 120))
	pointer_position = outside
	move_drag(outside)
	await create_timer(.15).timeout
	var preview: Window = app.drag_preview
	var decorated := false
	if is_instance_valid(preview):
		decorated = not preview.borderless
		if preview.has_meta(&"graffitty_window_frame"):
			var frame: Node = preview.get_meta(&"graffitty_window_frame")
			if frame.get_script() == preload("res://scenes/WindowFrameLinux.gd"):
				decorated = preview.borderless and frame.close.is_visible_in_tree() and frame.mode != frame.Mode.SYSTEM
	check(is_instance_valid(preview) and preview.visible and decorated, 'Dragging out already shows a decorated full native window')
	if preview == null: quit(1); return
	check(preview.size == root.size and preview.header.tabs.tab_count == 1, 'Preview keeps the window size and shows only the carried tab (source=%s preview=%s tabs=%s)' % [root.size, preview.size, preview.header.tabs.tab_count])
	check(preview.header.tabs.selected_id == tab and preview.header.tabs.buttons[tab].button_pressed, 'The carried tab is selected in the preview')
	if DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE):
		check(preview.extend_to_title and preview.header._title_margins.x > 0, 'Preview reserves native traffic-light space in the normal title strip')
	var grip := ScreenSpace.of(preview.header.tabs.buttons[tab], Vector2(preview._grab_x, preview._grab_y))
	check(grip.distance_to(outside) <= 1.0, 'The grabbed point stays under the pointer after adding native chrome (grip=%s pointer=%s)' % [grip, outside])
	if DisplayServer.get_name() != 'headless':
		RenderingServer.force_draw()
		var original := root.get_texture().get_image()
		var carried := preview.get_texture().get_image()
		var sample := Vector2i(original.get_width() * .8, original.get_height() * .8)
		var source_pixel := original.get_pixelv(sample)
		var preview_pixel := carried.get_pixelv(sample)
		check(preview.transparent == root.transparent, 'Detached preview preserves native window transparency')
		check(absf(source_pixel.a - preview_pixel.a) <= 1.0 / 255.0, 'Preview preserves configured background alpha (%s -> %s)' % [source_pixel.a, preview_pixel.a])
		check(Vector3(source_pixel.r, source_pixel.g, source_pixel.b).distance_to(Vector3(preview_pixel.r, preview_pixel.g, preview_pixel.b)) < .015, 'Preview composites the existing window colors once')
		var selected_rect: Rect2 = preview.header.tabs.buttons[tab].get_global_rect()
		var selected_pixel := carried.get_pixelv(Vector2i(preview.get_final_transform() * Vector2(selected_rect.get_center().x, selected_rect.end.y - 2)))
		# Compare the opening with the actual world at the same position. Below
		# the strip, pane backgrounds and shadows can change color and opacity.
		var world_pixels: Image = first.world_viewport.get_texture().get_image()
		var opening_uv := (preview.get_final_transform() * Vector2(selected_rect.get_center().x, selected_rect.end.y - 2)) / Vector2(carried.get_size())
		var below_tab: Color = world_pixels.get_pixelv(Vector2i(opening_uv * Vector2(world_pixels.get_size())))
		var frame_pixel := carried.get_pixelv(Vector2i(preview.get_final_transform() * Vector2(selected_rect.get_center().x, 3)))
		check(Vector3(selected_pixel.r, selected_pixel.g, selected_pixel.b).distance_to(Vector3(below_tab.r, below_tab.g, below_tab.b)) < .015 and absf(selected_pixel.a - below_tab.a) < .01, 'Preview selected tab visibly connects to the world beneath it')
		check(Vector3(selected_pixel.r, selected_pixel.g, selected_pixel.b).distance_to(Vector3(frame_pixel.r, frame_pixel.g, frame_pixel.b)) > .015, 'Preview selected tab is visually distinct from the surrounding frame')
		var evidence := OS.get_environment('GRAFFITTY_TEST_EVIDENCE')
		if not evidence.is_empty(): preview.get_texture().get_image().save_png(evidence.path_join('detach-preview.png'))
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.pressed = true
	root.push_input(cancel, true)
	deadline = Time.get_ticks_msec() + 1000
	while (not app.drag.is_empty() or is_instance_valid(preview)) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(app.drag.is_empty() and not is_instance_valid(preview) and app.hosts.size() == 1 and first.get_tabs().size() == 2, 'Escape removes the decorated preview without creating a session or losing a tab')
	await start_drag(first)
	pointer_position = outside
	move_drag(outside)
	await create_timer(.15).timeout
	preview = app.drag_preview
	var preview_identity := preview.get_window_id()
	var preview_position := preview.position
	await end_drag(outside)
	deadline = Time.get_ticks_msec() + 10000
	while app.hosts.size() < 2 and Time.get_ticks_msec() < deadline: await process_frame
	var detached: Node = app.hosts.back() if app.hosts.size() == 2 else null
	check(detached != null, 'Detaching one of several tabs creates a window')
	if detached == null: quit(1); return
	await settled(detached)
	check(detached.get_window() == preview and preview.get_window_id() == preview_identity and preview.position == preview_position, 'Drop reuses the exact preview window without replacing or moving it')
	check(not preview.unfocusable and not preview.get_flag(Window.FLAG_MOUSE_PASSTHROUGH), 'Committed detached window accepts normal focus and input')
	check(detached.session_backend.connection.workspace == '$2', 'New window attaches to new session $2')
	check(first.get_tabs().size() == 1 and detached.get_tabs().size() == 1, 'Each session owns exactly its tab')
	var detached_pid: int = detached.sessions[tab].term.get_shell_pid()
	var detached_identity: int = detached.get_window().get_window_id()
	await input_roundtrip(detached, tab, 'Detached session accepts input and returns shell output')
	# macOS destroys the native window on hide before its viewport releases
	# terminal focus. IME cleanup must tolerate that teardown order.
	var carried_terminal: Control = detached.sessions[tab].term
	carried_terminal.grab_focus()
	check(carried_terminal.has_focus(), 'Terminal holds focus before native window teardown')
	preview.hide()
	carried_terminal.release_focus()
	preview.show()
	carried_terminal.grab_focus()
	detached_identity = preview.get_window_id()
	await settled(detached)
	if DisplayServer.get_name() in ["X11", "Wayland"] and app.window_decorations == "client":
		var main_frame: Node = root.get_meta(&"graffitty_window_frame")
		var restored_frame: Node = preview.get_meta(&"graffitty_window_frame")
		check(preview.borderless and restored_frame.close.is_visible_in_tree() and restored_frame.mode == main_frame.mode,
			'Restored detached window keeps the same client frame as the main window')
	await input_roundtrip(detached, tab, 'Restored window still accepts terminal input after focus cleanup')
	# Direct the real tab input's continuing gesture using desktop coordinates;
	# no physical pointer or user window is moved by a background test.
	await start_drag(detached)
	var bar: Control = first.workspace_view.tab_bar.tabs
	var target := ScreenSpace.of(bar, Vector2(bar.size.x - 2, bar.size.y * .5))
	var content_target := ScreenSpace.of(first.workspace_view, first.workspace_view.size * .6)
	pointer_position = content_target
	move_drag(content_target)
	check(app.drag.get('mode') == app.DragMode.MERGE and not first.workspace_view.preview_plan.is_empty() and first.workspace_view.layout_preview.visible, 'Dragging over content shows a split placement preview')
	pointer_position = target
	move_drag(target)
	check(app.drag.get('mode') == app.DragMode.DOCKED, 'Moving the sole-tab window still recognizes another session tab bar')
	check(first.workspace_view.preview_plan.is_empty() and not first.workspace_view.layout_preview.visible and not first.workspace_view.drop_hint.visible and not app.drag.has('zone'), 'Moving from content to the same window tab bar clears all split hints')
	check(bar.external_drop_hint >= 0, 'Tab insertion remains visible after the split preview clears')
	pointer_position = content_target
	move_drag(content_target)
	check(not first.workspace_view.preview_plan.is_empty(), 'Moving back into content restores the split preview')
	pointer_position = target
	move_drag(target)
	check(first.workspace_view.preview_plan.is_empty(), 'Returning to the tab bar clears the split preview again')
	check(detached.get_window().get_window_id() == detached_identity and app.drag_preview == null, 'Merge preview retains the source window without a detached copy')
	await end_drag(target)
	deadline = Time.get_ticks_msec() + 10000
	while first.get_tabs().size() != 2 and Time.get_ticks_msec() < deadline: await process_frame
	await settled(first)
	check(first.get_tabs().size() == 2 and app.hosts.size() == 1, 'Dropping attaches the tab to the destination session and retires the empty source window')
	check(first.sessions.has(tab) and first.sessions[tab].term.get_shell_pid() == detached_pid, 'Transferred shell keeps its PID')
	check(first.workspace_layout.active == tab and first.pane_focus == "%%%d" % tab,
		"Completed tab-bar transfer selects and subscribes to the carried tab")
	await input_roundtrip(first, tab, 'Tab-bar transfer routes input through the destination session')
	await wrapper.connection.request_action('sync')
	check(not '1' in wrapper.connection.available_sessions, 'Empty source session is removed from the server inventory')
	check(first.sessions[pane].term.get_shell_pid() == pid, 'Destination shell is unchanged')
	# Repeat with a two-pane source tab, including an abandoned content preview.
	detached = await app.detach_workspace(first, tab, root.position + Vector2i(160, 120))
	await settled(detached)
	var split: Dictionary = await detached.session_backend.connection.request_action('create', {'kind':'pane', 'session':tab})
	await detached.session_backend.connection.request_action('sync')
	await settled(detached)
	var split_id := int(split.created)
	var split_pid: int = detached.sessions[split_id].term.get_shell_pid()
	await start_drag(detached)
	target = ScreenSpace.of(first.workspace_view, first.workspace_view.size * .6)
	pointer_position = target
	move_drag(target)
	check(app.drag.get('mode') == app.DragMode.MERGE, 'A sole tab with multiple panes can preview a content merge')
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	detached.get_window().push_input(escape, true)
	await process_frame
	await process_frame
	check(app.drag.is_empty() and app.hosts.size() == 2 and detached.sessions.size() == 2, 'Escape cancels the merge without losing a window or pane')
	await start_drag(detached)
	pointer_position = target
	move_drag(target)
	# The drop crosses sessions, but the window must keep showing its own tab
	# while the panes arrive: no switch to the carried tab, no tab transition.
	var destination_tab: int = first.workspace_layout.active
	var shown_tabs := {}
	var watch_tabs := func() -> void:
		if is_instance_valid(first): shown_tabs[first.workspace_layout.active] = true
	process_frame.connect(watch_tabs)
	await end_drag(target)
	deadline = Time.get_ticks_msec() + 10000
	while (app.hosts.size() != 1 or first.get_tabs().size() != 1 or first.sessions.size() != 3) and Time.get_ticks_msec() < deadline:
		await process_frame
	await settled(first)
	process_frame.disconnect(watch_tabs)
	check(shown_tabs.keys() == [destination_tab], 'A merge from another session keeps showing the destination tab: shown %s' % str(shown_tabs.keys()))
	check(app.hosts.size() == 1 and first.get_tabs().size() == 1 and first.sessions.size() == 3, 'Content drop merges every pane into the destination tab')
	check(first.sessions.has(split_id) and first.sessions[split_id].term.get_shell_pid() == split_pid, 'Multi-pane merge preserves the additional shell')
	await input_roundtrip(first, split_id, 'Content merge keeps every transferred pane interactive')
	await first.create_native_window()
	deadline = Time.get_ticks_msec() + 10000
	while app.hosts.size() != 2 and Time.get_ticks_msec() < deadline: await process_frame
	check(app.hosts.size() == 2, 'New Window control creates a second window')
	if app.hosts.size() == 2:
		var destination: Node = app.hosts.back()
		await settled(destination)
		check(destination.session_backend.connection.workspace.begins_with('$') and destination.session_backend.connection.workspace != first.session_backend.connection.workspace, 'New Window control creates a distinct server session')
		await start_drag(first)
		bar = destination.workspace_view.tab_bar.tabs
		target = ScreenSpace.of(bar, Vector2(bar.size.x - 2, bar.size.y * .5))
		pointer_position = target
		move_drag(target)
		await end_drag(target)
		deadline = Time.get_ticks_msec() + 10000
		while app.hosts.size() != 1 and Time.get_ticks_msec() < deadline: await process_frame
		await settled(destination)
		check(app.hosts.size() == 1 and destination.get_tabs().size() == 2, 'The original primary window can also merge into a later session')
		check(destination.sessions.has(pane) and destination.sessions[pane].term.get_shell_pid() == pid, 'Primary-window transfer preserves the original shell')
		await create_timer(2.0).timeout
		await input_roundtrip(destination, pane, 'Transferred terminal still accepts input after the primary window handoff')
	check(error_watch.errors.is_empty(), 'No engine or script errors: ' + str(error_watch.errors))
	if DisplayServer.get_name() != 'headless':
		await create_timer(.3).timeout
		RenderingServer.force_draw()
		var picture: Image = app.hosts.front().get_window().get_texture().get_image()
		var text_pixels := 0
		for y in range(120, picture.get_height(), 2):
			for x in range(0, picture.get_width(), 2):
				if picture.get_pixel(x, y).v > .65: text_pixels += 1
		check(text_pixels > 50, 'Transferred panes remain visible in the final rendered window')
		var output := OS.get_environment('GRAFFITTY_TEST_EVIDENCE')
		if not output.is_empty(): picture.save_png(output.path_join('world-tabs.png'))
	print('TAB_WINDOW_SESSION failures=', JSON.stringify(failures))
	for live in app.hosts.duplicate():
		live.get_parent().connection.disconnect_remote()
		live.get_parent().queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func check_host(wrapper: Node) -> bool:
	check(wrapper.host != null, 'Production local startup opens a terminal')
	if wrapper.host == null: quit(1); return false
	return true
