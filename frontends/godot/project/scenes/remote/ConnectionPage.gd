extends PanelContainer
## A scrollable connection screen, not an exclusive dialog. Shared by the server
## list and editor so Back, resizing and the Android keyboard behave identically.
const DesktopText := preload("res://scenes/DesktopText.gd")
signal confirmed
signal canceled
var heading := Label.new()
var header := CenterContainer.new()
var footer_actions := HBoxContainer.new()
var body := VBoxContainer.new()
var primary := Button.new()
var back := Button.new()
var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
var content := VBoxContainer.new()
## The editor stays narrow; device lists can opt into a wider layout.
var max_content_width := 600.0
var scroll_through_controls := false
var title := "":
	set(value):
		title = value
		heading.text = value
var ok_button_text := "Continue":
	set(value):
		ok_button_text = value
		primary.text = value

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := StyleBoxFlat.new()
	background.bg_color = Color("101720")
	add_theme_stylebox_override("panel", background)
	var layout := VBoxContainer.new()
	add_child(layout)
	layout.add_child(header)
	header.hide()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.scroll_deadzone = 8
	if scroll_through_controls:
		# Native ScrollContainer owns drag cancellation and inertia. Controls
		# must let touch events bubble up instead of stopping them at a button
		# or card panel. Include controls added later as servers change.
		add_child(preload("res://scenes/input/TouchScrollGesture.gd").new(self, scroll))
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	center.use_top_left = false
	scroll.add_child(center)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	center.add_child(margin)
	margin.add_child(content)
	content.add_theme_constant_override("separation", 18)
	heading.add_theme_font_size_override("font_size", DesktopText.size(28))
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(heading)
	body.add_theme_constant_override("separation", 14)
	content.add_child(body)
	var footer := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		footer.add_theme_constant_override("margin_" + side, 12)
	layout.add_child(footer)
	footer_actions.add_theme_constant_override("separation", 12)
	footer.add_child(footer_actions)
	style_button(primary, true)
	style_button(back)
	# A wrapping button has no text-width minimum. In this HBox the expanding
	# primary would squeeze Back to its padding, making the whole row very tall.
	back.autowrap_mode = TextServer.AUTOWRAP_OFF
	primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	primary.custom_minimum_size.y = 48
	primary.pressed.connect(func(): confirmed.emit())
	footer_actions.add_child(primary)
	back.text = "Back"
	back.custom_minimum_size.y = 48
	back.pressed.connect(func(): canceled.emit())
	footer_actions.add_child(back)
	scroll.resized.connect(_resize_content)
	scroll.get_v_scroll_bar().visibility_changed.connect(_resize_content)
	get_viewport().size_changed.connect(_resize_content)
	_resize_content()

func _resize_content() -> void:
	content.custom_minimum_size.x = available_content_width()

func available_content_width() -> float:
	var scrollbar := scroll.get_v_scroll_bar()
	var scrollbar_width := scrollbar.get_combined_minimum_size().x if scrollbar.visible else 0.0
	# The old content minimum can keep the ScrollContainer wider than the
	# viewport after rotation. Derive the new limit from the viewport itself
	# to break that minimum-size feedback loop and allow portrait shrinkage.
	var available := scroll.size.x
	if is_inside_tree(): available = minf(available, get_viewport_rect().size.x)
	return maxf(0, minf(max_content_width, available - scrollbar_width - 40))

func reveal_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and scroll.is_ancestor_of(focus): scroll.ensure_control_visible(focus)

func get_ok_button() -> Button:
	return primary

func get_contents_minimum_size() -> Vector2:
	return content.get_combined_minimum_size()

static func style_button(button: Button, primary_action := false) -> void:
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = preload("res://scenes/UIAccent.gd").PRIMARY if primary_action else Color("293847")
		if state == "hover": style.bg_color = style.bg_color.lightened(.12)
		if state == "pressed": style.bg_color = style.bg_color.darkened(.15)
		if state == "disabled": style.bg_color = Color("293847")
		style.set_corner_radius_all(8)
		style.content_margin_left = 12
		style.content_margin_right = 12
		button.add_theme_stylebox_override(state, style)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = preload("res://scenes/UIAccent.gd").ACCENT
	focus.set_border_width_all(2)
	focus.set_corner_radius_all(8)
	button.add_theme_stylebox_override("focus", focus)
