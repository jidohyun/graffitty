extends SceneTree
var failures := 0
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", message)
func run() -> void:
	# The production node-added handler, without starting any session server.
	var app := preload("res://scenes/TerminalApplication.gd").new()
	node_added.connect(app._configure_dialog)
	var menu := PopupMenu.new()
	menu.add_item("Close pane", 1)
	root.add_child(menu)
	await process_frame
	var submenu := PopupMenu.new()
	menu.add_child(submenu)
	await process_frame
	for popup in [menu, submenu]:
		check(popup.has_node("PopupChrome"), "Dynamic menus and submenus receive shared chrome")
		check(popup.theme != null, "Shared popup theme is installed")
	check(menu.get_item_id(0) == 1, "Action identity is unchanged")
	node_added.disconnect(app._configure_dialog)
	menu.free()
	app.free()
	print("POPUP_CHROME_PASS" if failures == 0 else "POPUP_CHROME_FAIL")
	quit(1 if failures else 0)
