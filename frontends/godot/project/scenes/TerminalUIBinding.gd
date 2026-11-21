extends Node
## Child of a world-owned control: freeing it automatically disconnects signals.
var host: Node
var control: Control
var kind := ""
var session_id := -1 # -1 follows the active session.
var _updating := false


func _ready() -> void:
	host.ui_changed.connect(_refresh)
	if kind == "tabs":
		control.tab_changed.connect(_select_tab)
		control.resized.connect(_refresh)
		control.clip_tabs = true
		control.scrolling_enabled = true
		control.focus_mode = Control.FOCUS_NONE
	elif kind == "scroll":
		control.step = 0.0
		control.custom_step = 1.0 # Arrow buttons still move one row.
		control.value_changed.connect(_scroll)
		control.focus_mode = Control.FOCUS_NONE
	_refresh()


func _session() -> Node:
	return host.session_model(host.active_session_id if session_id < 0 else session_id)


func _refresh() -> void:
	_updating = true
	var model: Node = _session()
	match kind:
		"tabs":
			var items: Array = host.get_tabs(true)
			while control.tab_count > items.size():
				control.remove_tab(control.tab_count - 1)
			while control.tab_count < items.size():
				control.add_tab("")
			var budget := clampi(floori(control.size.x / maxf(items.size(), 1.0)), 80, 240)
			control.max_tab_width = budget
			var font: Font = control.get_theme_font("font")
			var font_size: int = control.get_theme_font_size("font_size")
			for i in items.size():
				var title := str(items[i].title)
				var prefix := "%d: " % (i + 1)
				if items[i].progress_state != 0 and items[i].progress_value >= 0:
					prefix += "%d%% " % items[i].progress_value
				var path := title.begins_with("/") or title.begins_with("~")
				var full := prefix + title
				while (
					title.length() > 1
					and font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
					> budget - 24
				):
					title = title.substr(1) if path else title.left(-1)
					full = prefix + ("…" + title if path else title + "…")
				control.set_tab_title(i, full)
				control.set_tab_metadata(i, items[i].id)
				control.set_tab_tooltip(i, items[i].title)
				if items[i].id == host.workspace_layout.active:
					control.current_tab = i
		"title":
			control.text = model.title if model != null else ""
		"progress":
			var state: int = model.progress_state if model != null else 0
			var value: int = model.progress_value if model != null else -1
			control.visible = state != 0
			control.max_value = 100
			control.value = maxi(value, 0)
			control.indeterminate = state == 3 or value < 0
			# Theme authors may style states or replace this control entirely.
			control.set_meta("progress_state", state)
			control.tooltip_text = ["", "Running", "Error", "Working", "Paused"][state]
		"scroll":
			var enabled: bool = (
				model != null and model.capabilities().scroll and not model.alternate_screen
			)
			control.max_value = model.scroll_total if model != null else 0
			control.page = model.scroll_page if model != null else 0
			control.value = model.scroll_offset if model != null else 0
			control.visible = enabled and model.scroll_total > model.scroll_page
			# A pull past either end shortens the thumb (TerminalScrollBar).
			if "terminal" in control: control.terminal = model.terminal if model != null else null
	_updating = false


func _select_tab(index: int) -> void:
	if not _updating:
		host.select_workspace(int(control.get_tab_metadata(index)))


func _scroll(value: float) -> void:
	var model := _session()
	if not _updating and model != null:
		model.scroll_to(value)
