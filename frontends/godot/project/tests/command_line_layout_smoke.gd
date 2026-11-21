extends SceneTree
## Layout fixture; no connections, terminals, or input to a live session.
class Host extends Control:
	signal ui_changed
	signal active_session_changed(id)
	var workspace_view: Control
	func get_tabs() -> Array: return []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(320, 480)
	root.content_scale_size = root.size
	var host := Host.new()
	root.add_child(host)
	var command := preload("res://scenes/CommandLine.gd").new()
	command.host = host
	host.add_child(command)
	command._apply_theme()
	command.visible = true
	for index in 30:
		command.model.rows.append({"candidate": {"kind":"command", "label":"LongCommandName".repeat(5), "title":"A long description".repeat(10), "detail":"Ctrl+Shift+W"}, "indices":[], "tier":0})
	for inset in [0.0, 240.0, 300.0, 0.0]:
		command.set_bottom_inset(inset)
		command.model.selected = 29
		command._render()
		await process_frame
		await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(320, 480 - inset))
		assert(bounds.encloses(command._root.get_global_rect()), "Completion and input fit keyboard-safe phone bounds")
		assert(command._list.get_child_count() > 0, "Selected completion stays reachable")
		assert(command._status.text == "30/30", "Page reports the selected completion")
	host.queue_free()
	await process_frame
	print("COMMAND_LINE_LAYOUT_PASS")
	quit()
