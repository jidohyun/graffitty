extends Node
## Show Graffitty errors and warnings in a dockable window.
##
## By default the panel takes its own row below the status line. It shrinks
## the terminal area and leaves the side docks and status line visible.
signal diagnostics_shown(entries: Array)
const Diagnostics := preload("res://graffitty/diagnostics.gd")
## Visible exactly while messages are presented; lives inside `window` then.
var panel: PanelContainer
## Selects and scrolls like a terminal; on Android the system selects.
var messages := preload("res://scenes/SelectableText.gd").new()
var actions: VBoxContainer
var log_button: Button
var dismiss_button: Button
var window: Window
# Newest entry when the panel was last dismissed: new errors then show only what
# arrived after it, not the whole session's history again. Messages lists all.
var dismissed_entry: Variant = null
var showing_history := false
var log_viewer: AcceptDialog
var log_text: Control


func _ready() -> void:
	panel = PanelContainer.new()
	panel.hide()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxEmpty.new()
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	messages.follow_end = true
	# The Android scrollbar sits in the panel's 6 px margin, against its edge.
	messages.bar_outside = true
	messages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	messages.set_font_color(Color("#ffd6d6"))
	row.add_child(messages)
	actions = VBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	row.add_child(actions)
	log_button = Button.new()
	log_button.text = "Open log"
	log_button.focus_mode = Control.FOCUS_NONE
	log_button.pressed.connect(open_log)
	actions.add_child(log_button)
	dismiss_button = Button.new()
	dismiss_button.text = "Dismiss"
	dismiss_button.focus_mode = Control.FOCUS_NONE
	dismiss_button.pressed.connect(dismiss_messages)
	actions.add_child(dismiss_button)
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		for action in [log_button, dismiss_button]: action.custom_minimum_size = Vector2(80, 48)
	# A floating messages window receives its own keys, which the host's input
	# handler never sees: copy from the focused text itself.
	messages.view.gui_input.connect(func(event: InputEvent):
		if handle_shortcut(event): messages.view.accept_event())
	get_node("/root/DiagnosticService").changed.connect(refresh)
	refresh()


func _exit_tree() -> void:
	if is_instance_valid(window): window.queue_free()
	window = null


func refresh() -> void:
	var entries: Array = Diagnostics.history if showing_history else _undismissed()
	if entries.is_empty():
		_withdraw()
		return
	var lines := PackedStringArray()
	for entry in entries:
		lines.append(
			"%s: %s\n%s%s"
			% [
				tr("Warning") if entry.warning else tr("Error"),
				# User-facing warnings are catalog messages; engine and config
				# diagnostics stay as logged.
				tr(entry.message),
				entry.file,
				":%d" % entry.line if entry.line > 0 else "",
			]
		)
	messages.text = "\n\n".join(lines)
	_present()
	diagnostics_shown.emit(entries.duplicate(true))


## Opens the dockable window around the content. New entries while it is open
## only update the text: they never re-raise or refocus the window.
func _present() -> void:
	if is_instance_valid(window):
		panel.show()
		return
	if not is_inside_tree():
		panel.show()
		return
	# One OS window shows the shared diagnostics once, whichever host is in it.
	var owner_window := get_window()
	if owner_window.has_meta(&"diagnostic_panel"):
		var shown: Variant = owner_window.get_meta(&"diagnostic_panel")
		if is_instance_valid(shown) and shown != self and is_instance_valid(shown.window): return
	owner_window.set_meta(&"diagnostic_panel", self)
	panel.show()
	window = preload("res://scenes/MessagesWindow.gd").new()
	window.controller = self
	get_window().add_child(window)
	panel.reparent(window.slot)
	window.present()


## Hides the content and returns it here before the window leaves the dock.
func _withdraw() -> void:
	panel.hide()
	if not is_instance_valid(window): return
	var closing: Window = window
	window = null
	if panel.get_parent() != self: panel.reparent(self)
	closing.release()


## A compact dock row keeps only the message text.
func set_compact(compact: bool) -> void:
	actions.visible = not compact


# Entries after the dismissed one. If history trimmed it away, every remaining
# entry arrived later.
func _undismissed() -> Array:
	var history := Diagnostics.history
	if dismissed_entry != null:
		for index in range(history.size() - 1, -1, -1):
			if is_same(history[index], dismissed_entry):
				return history.slice(index + 1)
	return history


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and panel != null and panel.visible:
		refresh()


func dismiss_messages() -> void:
	dismissed_entry = null if Diagnostics.history.is_empty() else Diagnostics.history.back()
	showing_history = false
	_withdraw()


func show_history() -> void:
	showing_history = true
	refresh()


func copy_text() -> String:
	var selected := messages.get_selected_text()
	return selected if not selected.is_empty() else messages.text


func copy_messages() -> void:
	DisplayServer.clipboard_set(copy_text())


func handle_shortcut(event: InputEvent) -> bool:
	if not panel.visible or not messages.view.has_focus() or not event is InputEventKey:
		return false
	var command: bool = event.meta_pressed if OS.get_name() == "macOS" else event.ctrl_pressed
	if event.keycode != KEY_C or not command or event.alt_pressed: return false
	if event.pressed and not event.echo: copy_messages()
	return true


func open_log() -> void:
	# One viewer everywhere; on Android its text is the native selectable view.
	if is_instance_valid(log_viewer):
		log_viewer.popup_centered()
		return
	log_viewer = AcceptDialog.new()
	log_viewer.title = "Graffitty log"
	var text := preload("res://scenes/SelectableText.gd").new()
	log_text = text
	text.follow_end = true
	text.bar_outside = true
	text.set_font_color(Color("#eeeeee"))
	text.custom_minimum_size = Vector2(640, 360).min(get_viewport().get_visible_rect().size * .75)
	log_viewer.add_child(text)
	text.text = FileAccess.get_file_as_string(Diagnostics.log_path())
	add_child(log_viewer)
	log_viewer.confirmed.connect(log_viewer.queue_free)
	log_viewer.canceled.connect(log_viewer.queue_free)
	log_viewer.popup_centered()
