extends "../../../../tests/llm-e2e/replay/replay.gd"
## Two clients on one workspace: whichever was used last sizes the main area.
## A second local connection stands in for a phone that claims a portrait area.
const PORTRAIT := Rect2(0, 34, 412, 846)


func tab_state(connection: Node) -> Dictionary:
	for tab in connection.topology.get("tabs", []):
		if int(tab.id) == host.workspace_layout.active:
			return tab
	return {}


func area_of(connection: Node) -> Rect2:
	var area: Array = tab_state(connection).get("area", [0, 0, 0, 0])
	return Rect2(area[0], area[1], area[2], area[3])


func owner_of(connection: Node) -> String:
	return str(tab_state(connection).get("size_owner", ""))


func until(predicate: Callable, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()


func phone_claims(phone: Node) -> void:
	var tab: int = host.workspace_layout.active
	var state: Dictionary = phone.topology.workspace_state
	phone.send_action("workspace_edit", -1, {"expected_revision": int(phone.topology.workspace_revision), "claim": true,
		"edit": {"op": "tab", "tab": tab, "layout": state.layout.tabs[str(tab)],
			"settings": {"area": [PORTRAIT.position.x, PORTRAIT.position.y, PORTRAIT.size.x, PORTRAIT.size.y]}}})


func play() -> void:
	var desktop: Node = host.get_parent().connection
	var fitted: Rect2 = host.workspace_view.window_fit_rect()
	check(await until(func(): return owner_of(desktop) == "self" and area_of(desktop).is_equal_approx(fitted)),
		"Attaching claims the main area for this window")
	var phone: Node = load("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(phone)
	phone.connect_shared({"workspace": desktop.workspace, "capabilities": {"require_workspace": true}})
	check(await until(func(): return phone.connected and owner_of(phone) == "other"), "A second client sees the area as another client's")
	phone_claims(phone)
	check(await until(func(): return owner_of(desktop) == "other" and area_of(desktop).is_equal_approx(PORTRAIT)),
		"The desktop receives the phone's newer claim")
	await hold(0.5)
	check(owner_of(desktop) == "other" and host.workspace_view.content_rect().is_equal_approx(PORTRAIT),
		"The desktop letterboxes the phone's area without pushing its own size back")
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = KEY_SHIFT
		key.pressed = pressed
		Input.parse_input_event(key)
	check(await until(func(): return owner_of(desktop) == "self" and area_of(desktop).is_equal_approx(fitted)),
		"Input on the desktop takes the area back")
	check(await until(func(): return owner_of(phone) == "other" and area_of(phone).is_equal_approx(fitted)),
		"The phone now letterboxes the desktop's area")
	phone_claims(phone)
	check(await until(func(): return owner_of(desktop) == "other"), "The phone claims again")
	root.size = Vector2i(1100, 760)
	root.content_scale_size = Vector2i(1100, 760)
	check(await until(func(): return (owner_of(desktop) == "self"
			and area_of(desktop).is_equal_approx(host.workspace_view.window_fit_rect())
			and not area_of(desktop).is_equal_approx(PORTRAIT))),
		"Resizing the desktop window is the latest activity and takes the area")
	phone.disconnect_remote()
	phone.queue_free()
