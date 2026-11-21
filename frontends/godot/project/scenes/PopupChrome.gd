extends Node
## Shared in-app popup chrome, including dynamically created context menus.
## PopupMenu owns commands. Native desktop presentation stays with Godot;
## touch presentation owns bounded layout and pointer arbitration in TouchMenu.
const DesktopText := preload("res://scenes/DesktopText.gd")
const TouchMenu := preload("res://scenes/input/TouchMenu.gd")
const FloatingButtons := preload("res://scenes/input/FloatingButtons.gd")

static func presentation(menu: PopupMenu) -> Window:
	var ref: WeakRef = menu.get_meta(&"touch_presentation") if menu.has_meta(&"touch_presentation") else null
	var touch: Window = ref.get_ref() if ref != null else null
	return touch if is_instance_valid(touch) else menu

static func is_open(menu: PopupMenu) -> bool:
	var window := presentation(menu)
	return window.visible or (window is TouchMenu and window.pending)

static func close(menu: PopupMenu) -> void:
	var window := presentation(menu)
	if window is TouchMenu: window.dismiss()
	else: window.hide()

## Marks a destructive item: red icon and red text. Neither OS menus nor Godot's
## PopupMenu can color one item's text, so such menus are always app-drawn.
static func mark_danger(menu: PopupMenu, index: int) -> void:
	menu.set_item_icon_modulate(index, preload("res://scenes/UIAccent.gd").DANGER)
	menu.set_item_metadata(index, {"danger": true})


static func is_danger(menu: PopupMenu, index: int) -> bool:
	var data: Variant = menu.get_item_metadata(index)
	return data is Dictionary and data.get("danger", false)


static func has_danger(menu: PopupMenu) -> bool:
	for index in menu.item_count:
		if is_danger(menu, index): return true
	return false


static func open(menu: PopupMenu) -> void:
	if not preload("res://scenes/input/InteractionProfile.gd").touch_controls() and not has_danger(menu):
		menu.popup()
		return
	apply(menu)
	var touch := presentation(menu) as TouchMenu
	if touch == null:
		touch = TouchMenu.new()
		var owner := menu.get_parent()
		while owner is PopupMenu: owner = owner.get_parent()
		owner.add_child(touch)
		menu.set_meta(&"touch_presentation", weakref(touch))
		menu.tree_exiting.connect(touch.queue_free)
	for other in menu.get_tree().get_nodes_in_group(&"touch_menus"):
		if other != touch: other.dismiss()
	# Inherit the current IME exclusion even if no keyboard event occurs while open.
	for controls in menu.get_tree().get_nodes_in_group(&"floating_controls"):
		if controls is FloatingButtons:
			touch.bottom_inset = controls.bottom_inset
			break
	touch.request_present(menu, Vector2(menu.position))

static func open_button(button: MenuButton) -> void:
	if not preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		button.show_popup()
		return
	button.about_to_popup.emit()
	var menu := button.get_popup()
	menu.position = Vector2i(button.get_global_transform_with_canvas() * Vector2(0, button.size.y))
	open(menu)
static func apply(menu: PopupMenu) -> void:
	if not is_instance_valid(menu) or menu.has_node("PopupChrome"): return
	var chrome := new()
	chrome.name = "PopupChrome"
	menu.add_child(chrome)
	chrome.configure(menu)

const INK := Color("fafafa")
var popup: PopupMenu
var skin := Theme.new()
var panel := StyleBoxFlat.new()
var hover := StyleBoxFlat.new()
var motion: Tween

func configure(menu: PopupMenu) -> void:
	popup = menu
	panel.set_corner_radius_all(10)
	panel.set_border_width_all(1)
	panel.set_content_margin_all(8)
	panel.shadow_size = 10
	panel.shadow_offset = Vector2(0, 3)
	hover.set_corner_radius_all(6)
	skin.set_stylebox("panel", "PopupMenu", panel)
	skin.set_stylebox("hover", "PopupMenu", hover)
	var separator := StyleBoxLine.new()
	separator.color = Color(1, 1, 1, .12)
	separator.thickness = 1
	separator.grow_begin = -4
	separator.grow_end = -4
	skin.set_stylebox("separator", "PopupMenu", separator)
	skin.set_font_size("font_size", "PopupMenu", DesktopText.size(16))
	skin.set_constant("v_separation", "PopupMenu", 22)
	skin.set_constant("h_separation", "PopupMenu", 12)
	popup.theme = skin
	popup.transparent_bg = true
	popup.transparent = true
	popup.visibility_changed.connect(_visibility_changed)
	popup.about_to_popup.connect(_fit_scale)
	_set_opacity(1.0)

func _fit_scale() -> void:
	if popup.is_embedded(): return
	var owner := preload("res://scenes/WindowScale.gd").native_owner(popup)
	popup.current_screen = owner.current_screen
	popup.content_scale_factor = owner.content_scale_factor

func _visibility_changed() -> void:
	if motion != null: motion.kill()
	if not popup.visible: return
	_set_opacity(0.0)
	_animate_open.call_deferred()

func _animate_open() -> void:
	if not popup.visible: return
	motion = create_tween()
	motion.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	motion.tween_method(_set_opacity, 0.0, 1.0, .18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _set_opacity(value: float) -> void:
	panel.bg_color = Color(.055, .055, .065, .96 * value)
	panel.border_color = Color(1, 1, 1, .14 * value)
	panel.shadow_color = Color(0, 0, 0, .25 * value)
	hover.bg_color = Color(preload("res://scenes/UIAccent.gd").PRIMARY, .28 * value)
	for item in ["font_color", "font_hover_color", "font_pressed_color"]:
		skin.set_color(item, "PopupMenu", Color(INK, value))
	skin.set_color("font_disabled_color", "PopupMenu", Color(INK, .35 * value))
	skin.set_color("font_accelerator_color", "PopupMenu", Color(INK, .50 * value))
	skin.set_color("font_separator_color", "PopupMenu", Color(INK, .50 * value))
