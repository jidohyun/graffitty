extends PanelContainer
## Floating Android/Windows/Linux menu, without reserving a menu-bar row.
signal expanded_changed(value: bool)
const Icons := preload("res://scenes/PaneIcons.gd")
const Popups := preload("res://scenes/PopupChrome.gd")
const GROUP_ICONS := {"Shell": "square-terminal", "Edit": "square-pen", "View": "eye", "Sessions": "panels-top-left", "Help": "circle-help"}
const COLLAPSED_WIDTH := 60.0
const HEIGHT := 44.0
var buttons := HBoxContainer.new()
var expand_button := Button.new()
var collapse_button := Button.new()
var row := HBoxContainer.new()
var expanded := false
var progress := 0.0
var top := 8.0
var motion: Tween
var surface := StyleBoxFlat.new()
var content := Control.new()
var mover := preload("res://scenes/input/FloatingButtons.gd").new()
var closed_on_frame: Dictionary = {}

func _init() -> void:
	name = "MobileMenu"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	surface.set_corner_radius_all(30)
	surface.set_border_width_all(1)
	surface.shadow_size = 8
	surface.shadow_offset = Vector2(0, 2)
	surface.set_content_margin_all(8)
	surface.content_margin_top = 0
	surface.content_margin_bottom = 0
	# A low ellipse, with a full 44-point touch target around it.
	surface.expand_margin_top = -6
	surface.expand_margin_bottom = -6
	# A true pill outline: StyleBoxFlat's own round border looked dashed.
	add_theme_stylebox_override("panel", preload("res://scenes/input/RoundOutlineStyle.gd").new(surface))
	content.custom_minimum_size = Vector2(44, 44)
	content.clip_contents = true
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(content)
	content.add_child(row)
	row.add_theme_constant_override("separation", 4)
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.begin_touch_drag = func(travel: Vector2) -> bool:
		if absf(travel.x) < absf(travel.y) or mover.is_repositioning(): return false
		mover.cancel_gesture()
		return true
	row.add_child(scroll)
	buttons.add_theme_constant_override("separation", 0)
	scroll.add_child(buttons)
	style_button(collapse_button, "chevron-up", "Collapse menu")
	collapse_button.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	row.add_child(collapse_button)
	style_button(expand_button, "ellipsis", "Expand menu")
	content.add_child(expand_button)
	expand_button.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	row.hide()
	_set_progress(0.0)

func _ready() -> void:
	add_to_group(&"touch_chrome")
	get_viewport().size_changed.connect(reflow)
	buttons.minimum_size_changed.connect(reflow)
	mover.preferences_path = preload("res://graffitty/paths.gd").stdpath("config").path_join("touch-menu.conf")
	mover.animate_layout = false
	add_child(mover)
	# Godot visits later siblings first for _input. The icon strip must see
	# drag and lift before the floating control consumes a captured touch.
	move_child(mover, 0)
	mover.add_surface("menu", self, Vector2(.5, 0), {
		expand_button: set_expanded.bind(true),
		collapse_button: set_expanded.bind(false),
		self: Callable(),
	})
	reflow()

static func style_button(button: Button, icon_name: String, label: String) -> void:
	button.text = ""
	button.tooltip_text = label
	button.accessibility_name = label
	button.icon = Icons._texture("mobile-menu:" + icon_name, "res://scenes/icons/" + icon_name + ".svg", 1.0)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 24)
	button.custom_minimum_size = Vector2(44, 44)
	button.focus_mode = Control.FOCUS_NONE
	button.flat = true
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(preload("res://scenes/UIAccent.gd").ACCENT, .10) if state in ["hover", "pressed"] else Color.TRANSPARENT
		style.set_corner_radius_all(12)
		style.set_content_margin_all(8)
		button.add_theme_stylebox_override(state, style)

func add_menu(button: MenuButton, label: String) -> void:
	style_button(button, str(GROUP_ICONS.get(label, "settings")), label)
	button.name = label
	button.switch_on_hover = false
	buttons.add_child(button)
	button.get_popup().popup_hide.connect(func(): closed_on_frame[button] = Engine.get_process_frames())
	button.gui_input.connect(_menu_input.bind(button))
	button.about_to_popup.connect(func():
		for other in buttons.get_children():
			if other != button: Popups.close(other.get_popup()))

func _menu_input(event: InputEvent, button: MenuButton) -> void:
	var down: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) or (event is InputEventScreenTouch and event.pressed)
	if button.disabled: return
	# Capture intent on down: a popup may already have dismissed itself on this
	# press.
	#
	# All icons are drag handles, so suppress MenuButton's native press action
	# and only activate on a release that was not a hold/drag.
	var open := not Popups.is_open(button.get_popup())
	if down and closed_on_frame.get(button, -1) == Engine.get_process_frames(): open = false
	mover._surface_input(event, "menu", button, _activate_menu.bind(button, open))

func _activate_menu(button: MenuButton, open: bool) -> void:
	if not expanded or button.disabled: return
	if open: Popups.open_button(button)
	else: Popups.close(button.get_popup())

func set_expanded(value: bool, animate := true) -> void:
	expanded = value
	if motion != null: motion.kill()
	for button in buttons.get_children():
		button.disabled = not value
		if not value: Popups.close(button.get_popup())
	row.show()
	expand_button.hide()
	expanded_changed.emit(value)
	if animate and is_inside_tree():
		motion = create_tween()
		motion.tween_method(_set_progress, progress, 1.0 if value else 0.0, .24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		motion.tween_callback(_settled)
	else:
		_set_progress(1.0 if value else 0.0)
		_settled()

func _settled() -> void:
	row.visible = expanded
	expand_button.visible = not expanded

func _set_progress(value: float) -> void:
	progress = value
	surface.bg_color = Color(.055, .055, .065, lerpf(.10, .30, value))
	surface.border_color = Color(1, 1, 1, lerpf(.08, .16, value))
	surface.shadow_color = Color(0, 0, 0, lerpf(.10, .22, value))
	row.modulate.a = value
	expand_button.modulate.a = .70
	if is_inside_tree(): reflow()

func reflow() -> void:
	if not is_inside_tree(): return
	var available := get_viewport().get_visible_rect().size.x
	var width := minf(buttons.get_child_count() * 44.0 + 64.0, maxf(COLLAPSED_WIDTH, available - 24.0))
	row.size = Vector2(width - 16.0, 44)
	size = Vector2(lerpf(COLLAPSED_WIDTH, width, progress), HEIGHT)
	if mover.entries.has("menu"):
		mover.top_inset = maxf(0, top - mover.MARGIN)
		mover.layout()
	else:
		position = Vector2(maxf(0, (available - size.x) / 2), top)
