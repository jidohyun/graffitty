extends SceneTree
## Popup menus open under the finger when popups are embedded, as on Android,
## where the OS has no mouse position and DisplayServer reports the corner.
## Run: godot --headless --path frontends/godot/project --script res://tests/pointer_popup_smoke.gd
const PointerPopup := preload("res://scenes/input/PointerPopup.gd")
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func menu_under(parent: Node) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.add_item("Close pane")
	parent.add_child(menu)
	return menu

func run() -> void:
	# The Android profile embeds popups in the window, like TerminalApplication.
	# Headless has no pointer for the window itself, so this checks the menu
	# uses the window's own coordinates; the canvas case below checks values.
	root.gui_embed_subwindows = true
	root.size = Vector2i(800, 600)
	await process_frame
	var host := Node.new()
	root.add_child(host)
	var title_menu := menu_under(host)
	check(PointerPopup.embedder_of(title_menu) == root, "A host's menu embeds in the window")
	PointerPopup.open(title_menu)
	check(title_menu.visible and title_menu.position == Vector2i(root.get_mouse_position()), "It opens at the pointer in window coordinates (%s)" % title_menu.position)
	title_menu.hide()
	# Menus owned by pane content embed in the workspace canvas viewport.
	var canvas := SubViewport.new()
	canvas.size = Vector2i(400, 300)
	canvas.gui_embed_subwindows = true
	root.add_child(canvas)
	var reroute_menu := menu_under(canvas)
	var tap := InputEventMouseMotion.new()
	tap.position = Vector2(50, 40)
	canvas.push_input(tap)
	check(PointerPopup.embedder_of(reroute_menu) == canvas, "Canvas menus embed in the canvas")
	PointerPopup.open(reroute_menu)
	check(reroute_menu.position == Vector2i(50, 40), "They open at the pointer in canvas coordinates (%s)" % reroute_menu.position)
	reroute_menu.hide()
	var inner := SubViewport.new()
	inner.gui_embed_subwindows = false
	canvas.add_child(inner)
	check(PointerPopup.embedder_of(menu_under(inner)) == canvas, "A viewport that does not embed defers to its embedding ancestor")
	print("POINTER_POPUP failures=", failures)
	quit(1 if failures else 0)
