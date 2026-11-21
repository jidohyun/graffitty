extends Node
## Shared overflow, new-tab placement and searchable chooser for workspace and
## browser tabs. Owners supply metadata and selection actions, not layout rules.
const ActionStyle := preload("res://scenes/TabActionStyle.gd")
const ACTION_SIZE := 28.0
const ACTION_GAP := 8.0
var previous_tabs := Button.new()
var next_tabs := Button.new()
var all_tabs := Button.new()
var menu := preload("res://scenes/TabMenu.gd").new()
var tabs: Control
var group: Control
var refresh_menu: Callable
var before_show: Callable

func configure(parent: Control, strip: Control, refresh: Callable) -> void:
	group = parent
	tabs = strip
	refresh_menu = refresh
	for button in [previous_tabs, next_tabs, all_tabs]:
		button.focus_mode = Control.FOCUS_NONE
		group.add_child(button)
	previous_tabs.text = "‹"
	previous_tabs.accessibility_name = tr("Scroll tabs left")
	next_tabs.text = "›"
	next_tabs.accessibility_name = tr("Scroll tabs right")
	all_tabs.name = "AllTabs"
	all_tabs.tooltip_text = tr("Show all tabs") + " (:ShowAllTabs)"
	all_tabs.toggle_mode = true
	var layer := CanvasLayer.new()
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.MENU
	add_child(layer)
	layer.add_child(menu)
	menu.popup_hide.connect(func(): all_tabs.set_pressed_no_signal(false))
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(func():
		if menu.visible: refresh_menu.call())
	add_child(timer)
	menu.visibility_changed.connect(func():
		if menu.visible: timer.start()
		else: timer.stop())
	ActionStyle.apply(all_tabs, "M4 6 8 10 12 6", 8)
	ActionStyle.apply(tabs.plus, "M8 3v10M3 8h10", 14)
	previous_tabs.pressed.connect(func(): tabs.scroll_horizontal -= int(tabs.size.x * 0.7))
	next_tabs.pressed.connect(func(): tabs.scroll_horizontal += int(tabs.size.x * 0.7))
	all_tabs.pressed.connect(toggle)
	tabs.get_h_scroll_bar().value_changed.connect(func(_value): update_scroll_buttons())

func toggle() -> void:
	if menu.visible:
		menu.hide()
	else:
		if before_show.is_valid(): before_show.call()
		refresh_menu.call()
		all_tabs.set_pressed_no_signal(true)
		menu.show_below(all_tabs)

func layout(left: float, right: float, top_inset: float) -> void:
	var button_width := ACTION_SIZE + ACTION_GAP
	group.custom_minimum_size.x = left + right + button_width * 2
	var available := maxf(0.0, group.size.x - left - right - button_width * 2)
	var count: int = tabs.tab_count + (1 if tabs.external_drop_hint >= 0 else 0) - (
		1 if tabs._drag_external else 0
	)
	var minimum: float = maxf(
		tabs.minimum_tab_width,
		tabs
		.get_theme_font("font")
		.get_string_size(str(maxi(count, 1)), HORIZONTAL_ALIGNMENT_LEFT, -1, tabs.get_theme_font_size(
			"font_size"
		))
		.x
		+ 8,
	)
	if not tabs.compact_tabs: minimum = tabs.minimum_tab_width
	var overflow := count * (minimum + 3.0) > available
	var navigation_width := 0.0
	for button in [previous_tabs, next_tabs]:
		button.visible = overflow
		if overflow:
			navigation_width += maxf(28.0, button.get_combined_minimum_size().x)
	var width := minf(
		maxf(0.0, available - navigation_width),
		count * (tabs.maximum_tab_width + 3.0),
	)
	width = tabs.constrained_width(width)
	# Buttons can grow past 32 points to fit the theme's font and margins.
	# Leave space above them and join their bottom edge directly to the world.
	var tab_height := 34.0
	for button: Button in tabs.buttons.values():
		tab_height = maxf(tab_height, button.size.y)
	group.custom_minimum_size.y = tab_height + top_inset
	var tab_y := maxf(top_inset, group.size.y - tab_height)
	var action_y := tab_y + (tab_height - ACTION_SIZE) * 0.5
	all_tabs.position = Vector2(left, action_y)
	all_tabs.size = Vector2.ONE * ACTION_SIZE
	tabs.position = Vector2(left + button_width, tab_y)
	# TabContainer keeps its animated trailing edge visible during removal;
	# reducing the viewport to the final tab count would cut off the closing tab.
	var viewport_width := maxf(width, minf(maxf(0.0, available - navigation_width), tabs.animated_width()))
	tabs.size = Vector2(viewport_width, tab_height)
	tabs.plus.size = Vector2.ONE * ACTION_SIZE
	tabs.place_plus(Vector2(tabs.position.x + width + ACTION_GAP * 0.5, action_y))
	var x := tabs.position.x + width + button_width
	for button in [previous_tabs, next_tabs]:
		button.position = Vector2(x, 0)
		button.size = Vector2(maxf(28.0, button.get_combined_minimum_size().x), group.size.y)
		x += button.size.x
	update_scroll_buttons.call_deferred()


func update_scroll_buttons() -> void:
	var bar: HScrollBar = tabs.get_h_scroll_bar()
	previous_tabs.disabled = bar.value <= bar.min_value
	next_tabs.disabled = bar.value >= bar.max_value - bar.page - 1

