extends SceneTree
## Drives pointer events through the real server list page, including its touch
## scroll shield. Injected events are not a physical-device touch pass.
##     godot --headless --path . --script tests/server_reorder_smoke.gd [-- --touch-controls]
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
const Reorder := preload("res://scenes/remote/ServerReorder.gd")
const Card := preload("res://scenes/remote/ServerCard.gd")
const Model := preload("res://scenes/session/SessionsList.gd")
const Profile := preload("res://scenes/input/InteractionProfile.gd")
const NAMES := ["Z", "A", "M", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "B"]
var page := preload("res://scenes/remote/ServerBrowserPage.gd").new()
var cards := {}
var adapters := {}
var opened := 0
var failure := ""
var last := Vector2.ZERO
var failed := false

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-order-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(condition: bool, message: String) -> void:
	print(("PASS " if condition else "FAIL ") + message)
	if not condition: failed = true

func saved() -> Array:
	return Authentication.saved_connections().map(func(entry): return str(entry.name))

func shown() -> Array:
	return page.rows.get_children().filter(func(child): return child is Card).map(func(child): return str(child.heading.text))

## One pointer step: a touch (with the mouse Android emulates from it) or a mouse.
func point(at: Vector2, pressed: Variant = null) -> void:
	if Profile.touch_controls():
		var touch: InputEvent
		if pressed == null:
			touch = InputEventScreenDrag.new()
			touch.relative = at - last
		else:
			touch = InputEventScreenTouch.new()
			touch.pressed = pressed
		touch.position = at
		root.push_input(touch, true)
	var mouse: InputEventMouse
	if pressed == null:
		mouse = InputEventMouseMotion.new()
		mouse.button_mask = MOUSE_BUTTON_MASK_LEFT
		mouse.relative = at - last
	else:
		mouse = InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.pressed = pressed
	mouse.position = at
	mouse.global_position = at
	last = at
	root.push_input(mouse, true)
	await process_frame

func grip(name: String) -> Vector2:
	var rect: Rect2 = cards[name].select.get_global_rect()
	return Vector2(rect.position.x + 120, rect.get_center().y)

func settle() -> void:
	await create_timer(0.5).timeout

func run() -> void:
	root.size = Vector2i(600, 520)
	var entries := NAMES.map(func(name): return {"name": name, "url": "wss://%s.example" % name.to_lower()})
	var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").save_connections(Authentication.connection_path(), entries))
	assert(not result.has("error"), str(result))
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for entry in entries:
		var card := Card.new()
		page.rows.add_child(card)
		card.update_identity(entry)
		card.status.text = "Connected"
		card.update_state("connected", true)
		card.activated.connect(func(): opened += 1)
		cards[entry.name] = card
		adapters[entry.name] = Reorder.install(card.select, entry.url, func(error): failure = error, card)
	for i in 5: await process_frame
	var touch := Profile.touch_controls()
	print("mode: ", "touch" if touch else "mouse")
	check(page.scroll.get_v_scroll_bar().max_value > page.scroll.size.y, "Fixture list overflows its scroll page")
	var first: Control = cards["Z"]
	check([first.select, first.heading, first.address, first.os_icon].all(func(control): return control.get_tooltip().is_empty()), "Server card bodies have no duplicate identity tooltip")
	check(first.select.accessibility_name.contains("Z") and first.select.accessibility_name.contains("Connected"), "The card keeps its identity and status accessible")
	check(not first.more.get_tooltip().is_empty(), "The separate actions button keeps its explanatory hint")

	if touch:
		# A swipe belongs to the list: it scrolls and never lifts a card.
		var from := grip("M")
		await point(from, true)
		for i in 8: await point(from - Vector2(0, 14) * (i + 1))
		check(adapters["M"].state == Reorder.IDLE and not cards["M"].top_level, "A swipe does not lift a card")
		# Godot only touch-scrolls where the platform reports a touchscreen.
		if DisplayServer.is_touchscreen_available(): check(page.scroll.scroll_vertical > 0, "A swipe scrolls the list")
		await point(from - Vector2(0, 112), false)
		await settle()
		check(saved() == NAMES and opened == 0, "A swipe neither reorders nor opens a server")
		page.scroll.scroll_vertical = 0
		for i in 3: await process_frame

	# Lift Z and carry it below M.
	var start := grip("Z")
	await point(start, true)
	if touch:
		check(not cards["Z"].top_level, "A touch does not lift before the hold")
		await create_timer(Reorder.HOLD + 0.15).timeout
	else:
		await point(start + Vector2(0, 12))
	var z: Control = cards["Z"]
	check(adapters["Z"].state == Reorder.DRAGGING and z.top_level, "The card itself lifts")
	check(z.select.get_tooltip().is_empty(), "Holding to reorder does not add a duplicate tooltip")
	var gap_before: float = cards["A"].position.y
	var target := Vector2(start.x, cards["M"].select.get_global_rect().end.y - 6)
	for i in 10: await point(start.lerp(target, (i + 1) / 10.0))
	check(absf(z.get_global_rect().get_center().y - target.y) < z.size.y, "The lifted card follows the pointer")
	check(adapters["Z"]._slot_index() == 2, "The landing gap opens below the third card")
	check(not adapters["Z"].offsets.is_empty() or cards["A"].position.y < gap_before, "Neighbours slide to make room")
	check(page.scroll.scroll_vertical == 0, "Dragging a card does not scroll the list")
	await point(target, false)
	await settle()
	check(not z.top_level and adapters["Z"].state == Reorder.IDLE, "The card lands back in the list")
	check(shown() == ["A", "M", "Z"] + NAMES.slice(3), "The list shows the new order")
	check(saved() == shown() and failure.is_empty(), "The new order is saved")
	check(opened == 0, "Dropping a card does not open its server")
	check(Model.collect([], Authentication.saved_connections()).map(func(group): return group.id).slice(0, 3) == ["wss://a.example", "wss://m.example", "wss://z.example"], "Sessions groups follow the saved order")

	# Holding near the bottom edge scrolls so a card can travel past the screen.
	start = grip("A")
	await point(start, true)
	if touch: await create_timer(Reorder.HOLD + 0.15).timeout
	else: await point(start + Vector2(0, 12))
	var edge := Vector2(start.x, page.scroll.get_global_rect().end.y - 10)
	for i in 6: await point(start.lerp(edge, (i + 1) / 6.0))
	for i in 240:
		await process_frame
		if page.scroll.scroll_vertical >= page.scroll.get_v_scroll_bar().max_value - page.scroll.size.y: break
	check(page.scroll.scroll_vertical > 0, "Holding a card at the edge scrolls the list")
	await point(edge, false)
	await settle()
	check(saved()[-1] == "A" and saved() == shown(), "A card carried to the end is saved last")

	# Escape puts a lifted card back where it came from.
	page.scroll.scroll_vertical = 0
	for i in 3: await process_frame
	var order := saved()
	start = grip("M")
	await point(start, true)
	if touch: await create_timer(Reorder.HOLD + 0.15).timeout
	else: await point(start + Vector2(0, 12))
	for i in 6: await point(start + Vector2(0, 30) * (i + 1))
	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	root.push_input(escape)
	await point(start + Vector2(0, 180), false)
	await settle()
	check(saved() == order and shown() == order and not cards["M"].top_level, "Cancelling returns the card to its place")

	# A plain click still opens the server.
	if not touch:
		start = grip("M")
		await point(start, true)
		await point(start, false)
		check(opened == 1, "A click without a drag still opens the server")
	print("SERVER_REORDER_FAIL" if failed else "SERVER_REORDER_PASS (injected pointer events, not physical touch E2E)")
	quit(1 if failed else 0)
