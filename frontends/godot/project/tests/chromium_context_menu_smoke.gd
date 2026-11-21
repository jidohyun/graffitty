extends SceneTree
## Run without --headless to verify the platform's actual native menu backend.
class Chromium extends Node:
	var calls: Array = []
	func command(action: String, params: Dictionary) -> void:
		calls.append({"action": action, "params": params})

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-menu-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	_run.call_deferred()

func _run() -> void:
	root.gui_embed_subwindows = true
	var chromium := Chromium.new()
	root.add_child(chromium)
	var menu := preload("res://scenes/ChromiumContextMenu.gd").new()
	menu.chromium = chromium
	chromium.add_child(menu)
	menu._fill(menu, [{"id": 100, "type": 5, "label": "Speech", "items": [
		{"id": 101, "type": 1, "label": "Start Speaking"},
		{"id": 102, "type": 1, "label": "Stop Speaking", "enabled": false},
	]}])
	var child := menu.get_child(0) as PopupMenu
	var desktop := OS.get_name() in ["macOS", "Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]
	if desktop and NativeMenu.has_feature(NativeMenu.FEATURE_POPUP_MENU):
		assert(menu.is_native_menu() and child.is_native_menu())
		print("PASS native root and submenu")
	elif desktop and DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS):
		assert(not menu.is_embedded() and not child.is_embedded())
		print("PASS desktop popup windows")
	else:
		assert(menu.is_embedded() and child.is_embedded())
		print("PASS embedded popup fallback")
	assert(child.is_item_disabled(1))
	# Native close can precede selection; cancellation must not win that race.
	menu.menu_id = 17
	menu.popup_hide.emit()
	child.id_pressed.emit(101)
	await process_frame
	assert(chromium.calls == [{"action": "context-menu-select", "params": {"menu_id": 17, "command_id": 101}}])
	menu.menu_id = 18
	menu.popup_hide.emit()
	await process_frame
	assert(chromium.calls.size() == 2 and chromium.calls[1].params == {"menu_id": 18, "command_id": -1})
	print("PASS submenu selection, disabled state, and dismissal ordering")
	chromium.free()
	quit()
