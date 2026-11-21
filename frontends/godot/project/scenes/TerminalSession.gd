extends Node
## Persistent semantic state; worlds own presentation, never protocol parsing.
enum ProgressState {
	NONE,
	NORMAL,
	ERROR,
	INDETERMINATE,
	PAUSED,
}
signal changed
signal title_changed(title: String)
signal progress_changed(state: int, value: int)
signal scroll_changed(scroll: Dictionary)
signal bell
signal exited(code: int)

var id := -1
var terminal: Node
var _state: Dictionary = { }
var _exit_code: Variant = null
## A name given through the API. It stands over what programs set until it is
## cleared with an empty name.
var pinned_title := ""
## Only application-provided titles are translated; user/program titles are literal.
var builtin_title := "":
	set(value):
		if builtin_title == value: return
		builtin_title = value
		title_changed.emit(title)
		changed.emit()
## Remote fallback labels carry no program title or working-directory information.
var title_is_fallback := false
var initial_directory := ""
var shell := ""
## A remote session's owner has already normalized host-specific console titles.
## Its metadata is authoritative over the renderer's raw terminal checkpoint.
var owner_title: Variant = null
## Server-observed foreground identity, independent of agent turn/session status.
var foreground_app: Dictionary = {}
## Effect holds this pane's programs asked for (OSC 4723); see docs/developers/automation-and-extensions/effect-holds.md.
var effect_holds: Array = []
var title: String:
	get:
		if not pinned_title.is_empty():
			return pinned_title
		if not builtin_title.is_empty():
			return tr(builtin_title)
		if owner_title != null:
			return str(owner_title)
		var reported := str(_state.get("title", ""))
		if not reported.is_empty():
			return reported
		var path := cwd if not cwd.is_empty() else initial_directory
		if path.begins_with("file://"):
			# OSC 7 encodes an absolute path after the URI authority.
			var slash := path.find("/", 7)
			path = path.substr(slash).uri_decode() if slash >= 0 else ""
			if (
				OS.get_name() == "Windows" and path.length() > 3
				and path[0] == "/" and path[2] == ":"
			):
				path = path.substr(1)
		return path
var cwd: String:
	get:
		return str(_state.get("cwd", ""))
var progress_state: int:
	get:
		return int(_state.get("progress_state", ProgressState.NONE))
var progress_value: int:
	get:
		return int(_state.get("progress_value", -1))
var scroll_total: int:
	get:
		return int(_state.get("scroll_total", 0))
var scroll_offset: float:
	get:
		return float(_state.get("scroll_offset", 0)) + float(_state.get("scroll_fraction", 0.0))
var scroll_page: int:
	get:
		return int(_state.get("scroll_page", 0))
var alternate_screen: bool:
	get:
		return bool(_state.get("alternate_screen", false))
var has_exited: bool:
	get:
		return bool(_state.get("exited", false))
var exit_code: Variant:
	get:
		return _exit_code


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and not builtin_title.is_empty() and pinned_title.is_empty():
		title_changed.emit(title)
		changed.emit()


func configure(index: int, node: Node) -> void:
	id = index
	terminal = node
	initial_directory = str(terminal.get("working_directory"))
	terminal.title_changed.connect(_on_title)
	terminal.bell.connect(_on_bell)
	terminal.exited.connect(_on_exit)
	terminal.ui_state_changed.connect(refresh)
	refresh()


func capabilities() -> Dictionary:
	return {
		"title": terminal.has_signal("title_changed"),
		"progress": terminal.has_method("get_ui_state"),
		"scroll": terminal.has_method("scroll_to_row"),
		"cwd": terminal.has_method("get_ui_state"),
	}


func snapshot() -> Dictionary:
	var result := _state.duplicate(true)
	result["id"] = id
	result["exit_code"] = exit_code
	return result


func scroll_snapshot() -> Dictionary:
	return {
		"total": scroll_total,
		"offset": scroll_offset,
		"page": scroll_page,
		"alternate_screen": alternate_screen,
		"at_bottom": scroll_offset >= maxi(scroll_total - scroll_page, 0),
	}


func scroll_to(row: float) -> void:
	if (
		alternate_screen or not is_instance_valid(terminal)
		or not terminal.has_method("scroll_to_row")
	):
		return
	var target := clampf(row, 0.0, float(maxi(scroll_total - scroll_page, 0)))
	if terminal.has_method("scroll_to_position"):
		terminal.call("scroll_to_position", target)
	else:
		terminal.call("scroll_to_row", roundi(target))
	refresh()


func scroll_by(rows: int) -> void:
	scroll_to(scroll_offset + rows)


func scroll_to_bottom() -> void:
	scroll_to(maxi(scroll_total - scroll_page, 0))


func refresh() -> void:
	if not is_instance_valid(terminal) or not terminal.has_method("get_ui_state"):
		return
	var next: Dictionary = terminal.call("get_ui_state")
	if next == _state:
		return
	var old_title := title
	var old_progress := Vector2i(progress_state, progress_value)
	var old_scroll := scroll_snapshot()
	_state = next.duplicate(true)
	if not has_exited:
		_exit_code = null
	if title != old_title:
		title_changed.emit(title)
	if Vector2i(progress_state, progress_value) != old_progress:
		progress_changed.emit(progress_state, progress_value)
	if scroll_snapshot() != old_scroll:
		scroll_changed.emit(scroll_snapshot())
	changed.emit()


func _on_title(value: String) -> void:
	var shown := title
	_state["title"] = value
	if title != shown:
		title_changed.emit(title)
		changed.emit()


func pin_title(value: String) -> void:
	var shown := title
	pinned_title = value
	if title != shown:
		title_changed.emit(title)
		changed.emit()


func set_owner_title(value: String) -> void:
	var shown := title
	owner_title = value
	if title != shown:
		title_changed.emit(title)
		changed.emit()


func _on_bell() -> void:
	bell.emit()


func _on_exit(code: int) -> void:
	_exit_code = code
	_state["exited"] = true
	exited.emit(code)
	changed.emit()
