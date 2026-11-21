extends "res://tests/tab_overflow_smoke.gd"
const NativeFrame := preload("res://scenes/NativeWindowFrame.gd")
var directory := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
var strip: Control
var host: Node
var panel: Window
var preview: Window
var close_requests := 0
var sequence := 0


func run() -> void:
	if DisplayServer.get_name() != "Windows":
		print("SKIP Windows window-frame integration")
		quit()
		return
	auto_accept_quit = false
	root.gui_embed_subwindows = false
	root.title = "Graffitty Window Frame Test"
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(1000, 600)
	root.min_size = Vector2i(480, 300)
	root.close_requested.connect(
		func():
			close_requests += 1,
	)
	var background := ColorRect.new()
	background.color = Color("384250")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host = FakeHost.new()
	root.add_child(host)
	for i in 3:
		host.items.append(
			{
				"id": i + 1,
				"title": ["Terminal", "Editor", "Build"][i],
				"progress_state": 0,
				"progress_value": -1,
			}
		)
	strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	strip.bind_host(host)
	root.add_child(strip)
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	host.workspace_view = { "tab_bar": strip }
	for i in 20:
		await process_frame
	var elapsed := 0.0
	while elapsed < 180:
		var command_path := directory.path_join("command.json")
		if FileAccess.file_exists(command_path):
			var command: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(command_path))
			DirAccess.remove_absolute(command_path)
			sequence = int(command.sequence)
			match str(command.action):
				"scale":
					root.content_scale_factor = float(command.value)
				"mode":
					root.mode = int(command.value)
				"move":
					NativeFrame.move_window(root, Vector2i(command.x, command.y))
				"preview":
					preview = preload("res://scenes/TabDragPreview.gd").new()
					preview.configure(host, strip.tabs, 2)
					root.add_child(preview)
					preview.show()
					for i in 10:
						await process_frame
					preview.follow(Vector2(450, 260))
				"preview_move":
					preview.follow(Vector2(610, 340))
				"preview_close":
					preview.queue_free()
					preview = null
				"panel":
					panel = PopupPanel.new() if command.small else Window.new()
					panel.visible = false
					panel.force_native = true
					panel.borderless = true
					root.add_child(panel)
					panel.show()
				"panel_remap":
					panel.hide()
					panel.show()
				"panel_close":
					panel.queue_free()
					panel = null
				"quit":
					quit()
					return
			for i in 12:
				await process_frame
		var info := {
			"sequence": sequence,
			"hwnd": DisplayServer.window_get_native_handle(
				DisplayServer.WINDOW_HANDLE,
				root.get_window_id(),
			),
			"attached": is_instance_valid(strip._native_frame),
			"caption": Array(strip._native_frame.caption.state) if is_instance_valid(strip._native_frame) else [],
			"position": [root.position.x, root.position.y],
			"size": [root.size.x, root.size.y],
			"scale": root.content_scale_factor,
			"margins": [strip._title_margins.x, strip._title_margins.y, strip._title_margins.z],
			"bar": rect_data(strip),
			"tabs": rect_data(strip.tabs),
			"plus": rect_data(strip.tabs.plus),
			"mode": root.mode,
			"close_requests": close_requests,
			"active": host.workspace_layout.active,
		}
		if is_instance_valid(panel):
			info.panel_hwnd = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, panel.get_window_id())
		if is_instance_valid(preview):
			info.preview = {
				"hwnd": DisplayServer.window_get_native_handle(
					DisplayServer.WINDOW_HANDLE,
					preview.get_window_id(),
				),
				"attached": is_instance_valid(preview.header._native_frame),
				"position": [preview.position.x, preview.position.y],
				"grab": [preview.grab_offset.x, preview.grab_offset.y],
			}
		FileAccess.open(directory.path_join("state.tmp"), FileAccess.WRITE).store_string(
			JSON.stringify(info)
		)
		DirAccess.rename_absolute(
			directory.path_join("state.tmp"),
			directory.path_join("state.json"),
		)
		await create_timer(0.05).timeout
		elapsed += 0.05
	quit(2)


func rect_data(control: Control) -> Array:
	var rect := control.get_viewport().get_final_transform() * control.get_global_rect()
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
