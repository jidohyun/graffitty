extends SceneTree
class Home extends "res://scenes/remote/RemoteManager.gd":
	var activations := 0
	var additions := 0
	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		chooser.scroll_through_controls = true
		add_child(chooser)
		_build_home()
	func _activate(_key: String) -> void: activations += 1
	func _new_connection() -> void: additions += 1

var failures := 0
func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("manager-touch-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func expect(value: bool, text: String) -> void:
	if not value: failures += 1
	print(("PASS " if value else "FAIL ") + text)

func touch(point: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = point
	event.pressed = pressed
	Input.parse_input_event(event)

func drag(from: Vector2, to: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = to
	event.relative = to - from
	Input.parse_input_event(event)

func run() -> void:
	Input.emulate_mouse_from_touch = true
	root.gui_embed_subwindows = true
	root.size = Vector2i(540, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1
	root.notify_mouse_entered()
	if DisplayServer.get_name() != "headless": root.grab_focus()
	var before := Node.get_orphan_node_ids()
	var home := Home.new()
	root.add_child(home)
	var key := home._remember_entry({"url": "ws://example.test:7183", "hostname": "Build", "platform": "macos", "workspace": "$1"}, "connected", "Connected")
	var add: Button = home.connections_section.get_child(home.connections_section.get_child_count() - 1)
	var card: Button = home.cards[key].select
	var counter := {"hover": 0}
	home.settings_tab.mouse_entered.connect(func(): counter.hover += 1)
	await create_timer(.6).timeout
	expect(not home.chooser.scroll.get_v_scroll_bar().visible, "Real manager fixture exercises a list without overflow")
	var policy: Node
	for child in home.chooser.get_children():
		if child.get_script() == preload("res://scenes/input/TouchScrollGesture.gd"): policy = child
	# Positive control: the exact manager gesture leaks hover without capture.
	policy.set_process_input(false)
	var baseline_start := add.get_global_rect().get_center()
	var baseline_end := home.settings_tab.get_global_rect().get_center()
	touch(baseline_start, true)
	await process_frame
	drag(baseline_start, baseline_end)
	await process_frame
	expect(counter.hover > 0, "Same manager gesture reproduces the hover leak without shared capture")
	touch(baseline_end, false)
	await process_frame
	policy.set_process_input(true)
	for origin in [add, card]:
		var start: Vector2 = origin.get_global_rect().get_center()
		var target := home.settings_tab.get_global_rect().get_center()
		counter.hover = 0
		touch(start, true)
		await process_frame
		await process_frame
		expect(origin.get_draw_mode() == BaseButton.DRAW_PRESSED, "Original button still gets native press feedback: " + origin.name)
		drag(start, target)
		await process_frame
		expect(counter.hover == 0 and not home.settings_tab.is_hovered(), "Dragging from " + origin.name + " does not hover Settings")
		expect(not origin.has_focus(), "Dragging releases the original pointer focus")
		drag(target, start)
		touch(start, false)
		await process_frame
		expect(home.activations == 0 and home.additions == 0 and not home.settings_section.visible, "Returning and releasing cannot activate a canceled press")
	# Normal taps must still work, not merely look correct.
	for origin in [add, card]:
		var point: Vector2 = origin.get_global_rect().get_center()
		touch(point, true)
		await process_frame
		touch(point, false)
		await process_frame
	expect(home.additions == 1 and home.activations == 1, "Normal Add server and card taps remain functional")
	touch(home.settings_tab.get_global_rect().get_center(), true)
	touch(home.settings_tab.get_global_rect().get_center(), false)
	await process_frame
	expect(home.settings_section.visible, "Footer navigation still works after the gesture")
	home.queue_free()
	await process_frame
	for id in Node.get_orphan_node_ids():
		if id not in before:
			var node := instance_from_id(id)
			if is_instance_valid(node): node.free()
	quit(1 if failures else 0)
