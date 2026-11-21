extends PopupMenu
## Chromium supplies commands; Godot owns their placement over the embedded pane.
var chromium: Node
var menu_id := 0
const Popups := preload("res://scenes/PopupChrome.gd")

func _ready() -> void:
	_configure_popup(self)
	id_pressed.connect(_choose)
	popup_hide.connect(func():
		if menu_id != 0:
			_cancel_hidden.call_deferred(menu_id))

func _configure_popup(menu: PopupMenu) -> void:
	var desktop := OS.get_name() in ["macOS", "Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]
	menu.prefer_native_menu = desktop
	# Linux backends without native menus still need a popup above the pane,
	# rather than a subwindow clipped/occluded by the embedded browser surface.
	menu.force_native = desktop and DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS)

func _cancel_hidden(id: int) -> void:
	# Wait for `id_pressed` before cancelling the CEF callback. Native
	# Windows menus deliver it after the deferred `popup_hide` handlers.
	# Cancelling first would turn every selection into Cancel.
	await get_tree().process_frame
	if menu_id == id and not Popups.is_open(self):
		_choose(-1)

func _choose(command_id: int) -> void:
	if menu_id == 0:
		return
	var id := menu_id
	menu_id = 0
	chromium.command("context-menu-select", {"menu_id": id, "command_id": command_id})
	Popups.close(self)

func _fill(menu: PopupMenu, items: Array) -> void:
	for item in items:
		var label := str(item.get("label", "")).replace("&", "")
		var id := int(item.get("id", -1))
		var index := menu.item_count
		match int(item.get("type", 1)):
			4:
				menu.add_separator()
			5:
				var child := PopupMenu.new()
				child.name = "Menu%d" % index
				_configure_popup(child)
				menu.add_child(child)
				child.id_pressed.connect(_choose)
				_fill(child, item.get("items", []))
				menu.add_submenu_item(label, child.name, id)
			2:
				menu.add_check_item(label, id)
			3:
				menu.add_radio_check_item(label, id)
			_:
				menu.add_item(label, id)
		menu.set_item_disabled(index, not bool(item.get("enabled", true)))
		if int(item.get("type", 1)) in [2, 3]:
			menu.set_item_checked(index, bool(item.get("checked", false)))

func display(value: Dictionary) -> void:
	menu_id = 0
	Popups.close(self)
	clear()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var items: Array = value.get("items", [])
	if items.is_empty():
		return
	menu_id = int(value.id)
	_fill(self, items)
	reset_size()
	var at: Vector2 = chromium.context_menu_screen
	if is_embedded():
		var viewport := get_parent().get_viewport()
		at = viewport.get_screen_transform().affine_inverse() * (at - Vector2(viewport.get_window().position))
	position = Vector2i(at)
	Popups.open(self)
