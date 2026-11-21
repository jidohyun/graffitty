extends VBoxContainer
## Optional Never/After/At stop controls, matching Scheduled Trigger's end modes.
enum {
	NEVER,
	AFTER,
	AT,
}
var graph: Node
var edge_key := ""
var mode := OptionButton.new()
var date_time := LineEdit.new()
var duration := LineEdit.new()
var zone := Label.new()
var apply := Button.new()
var status := Label.new()
var offset_minutes := 0
var _saved := -1.0
var _dirty := false
var _applying := false


func _ready() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var label := Label.new()
	label.text = "Stop"
	row.add_child(label)
	for text in ["Never", "After", "At"]:
		mode.add_item(text)
	mode.tooltip_text = "Never stops automatically; After counts from Apply; At uses the displayed UTC offset."
	row.add_child(mode)
	date_time.placeholder_text = "HH:MM or YYYY-MM-DD HH:MM[:SS]"
	date_time.custom_minimum_size.x = 270
	date_time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(date_time)
	duration.text = "30m"
	duration.placeholder_text = "30s, 5m, 1h"
	duration.tooltip_text = "Duration from Apply: 100ms to 365d, using ms, s, m, h or d."
	duration.custom_minimum_size.x = 180
	duration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(duration)
	row.add_child(zone)
	apply.text = "Apply stop time"
	row.add_child(apply)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)
	mode.item_selected.connect(_mode_selected)
	date_time.text_changed.connect(
		func(_text):
			_edited(),
	)
	date_time.text_submitted.connect(
		func(_text):
			_apply(),
	)
	duration.text_changed.connect(
		func(_text):
			_edited(),
	)
	duration.text_submitted.connect(
		func(_text):
			_apply(),
	)
	apply.pressed.connect(_apply)
	visibility_changed.connect(_graph_changed)
	_set_zone()
	_sync_mode()
	refresh()


func bind_graph(value: Node, key: String) -> void:
	_disconnect_graph()
	graph = value
	edge_key = key
	_saved = -1.0
	_dirty = false
	_set_zone()
	if is_instance_valid(graph):
		graph.changed.connect(_graph_changed)
		graph.tree_exiting.connect(_graph_exiting)
	refresh()


func _set_zone() -> void:
	offset_minutes = int(Time.get_time_zone_from_system().bias)
	zone.text = offset_label(offset_minutes)


static func offset_label(minutes: int) -> String:
	return "UTC%s%02d:%02d" % ["+" if minutes >= 0 else "-", absi(minutes) / 60, absi(minutes) % 60]


static func format_time(timestamp: float, minutes: int) -> String:
	return Time.get_datetime_string_from_unix_time(int(timestamp) + minutes * 60, true)


static func parse_duration(text: String) -> Dictionary:
	for pair in [["ms", 0.001], ["s", 1.0], ["m", 60.0], ["h", 3600.0], ["d", 86400.0]]:
		var value := text.strip_edges()
		if not value.ends_with(pair[0]):
			continue
		var number := value.trim_suffix(pair[0]).strip_edges()
		if not number.is_valid_float():
			break
		var seconds := float(number) * float(pair[1])
		if is_finite(seconds) and seconds >= 0.1 and seconds <= 31536000.0:
			return { "result": roundf(seconds * 1000.0) / 1000.0 }
		break
	return { "error": "Duration must be from 100ms to 365d, e.g. 30s, 5m, or 1h." }


static func parse_time(text: String, minutes: int, now := -1.0) -> Dictionary:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	var source := text.strip_edges()
	var clock_pattern := RegEx.new()
	clock_pattern.compile("^[0-9]{2}:[0-9]{2}(?::[0-9]{2})?$")
	var clock_only := clock_pattern.search(source) != null
	if clock_only:
		source = Time.get_date_string_from_unix_time(int(now) + minutes * 60) + " " + source
	var pattern := RegEx.new()
	pattern.compile("^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?$")
	var found := pattern.search(source)
	if found == null:
		return { "error": "Use HH:MM or YYYY-MM-DD HH:MM, optionally with :SS." }
	var year := int(found.get_string(1))
	var month := int(found.get_string(2))
	var day := int(found.get_string(3))
	var hour := int(found.get_string(4))
	var minute := int(found.get_string(5))
	var second := int(found.get_string(6))
	var days := [
		31,
		29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28,
		31,
		30,
		31,
		30,
		31,
		31,
		30,
		31,
		30,
		31,
	]
	if (
		year < 1970 or month < 1 or month > 12 or day < 1
		or day > days[month - 1] or hour > 23 or minute > 59 or second > 59
	):
		return { "error": "Enter a valid date and time (year 1970 or later)." }
	var timestamp := Time.get_unix_time_from_datetime_dict(
		{
			"year": year,
			"month": month,
			"day": day,
			"hour": hour,
			"minute": minute,
			"second": second,
		}
	) - minutes * 60
	if clock_only and timestamp <= now:
		timestamp += 86400
	if timestamp <= 0:
		return { "error": "Stop time must be after the Unix epoch." }
	return { "result": timestamp }


func _disconnect_graph() -> void:
	if not is_instance_valid(graph):
		return
	if graph.changed.is_connected(_graph_changed):
		graph.changed.disconnect(_graph_changed)
	if graph.tree_exiting.is_connected(_graph_exiting):
		graph.tree_exiting.disconnect(_graph_exiting)


func _exit_tree() -> void:
	_disconnect_graph()


func _graph_exiting() -> void:
	_disconnect_graph()
	graph = null
	refresh()


func _graph_changed() -> void:
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	var edge: Dictionary = graph.edges.get(edge_key, { }) if is_instance_valid(graph) else { }
	if edge.is_empty():
		mode.disabled = true
		date_time.editable = false
		duration.editable = false
		apply.disabled = true
		status.text = "Connection is no longer available."
		return
	mode.disabled = false
	var deadline := float(edge.get("stop_at", 0.0))
	if deadline != _saved:
		_saved = deadline
		_dirty = false
		if not _applying:
			mode.select(AT if deadline > 0.0 else NEVER)
		date_time.text = format_time(deadline, offset_minutes) if deadline > 0.0 else ""
	date_time.editable = true
	duration.editable = true
	_sync_mode()
	apply.disabled = not _dirty and mode.selected != AFTER
	if _dirty:
		return
	if deadline <= 0.0:
		status.text = "No stop time."
	elif graph.connection_expired(edge):
		status.text = "Stop time reached. Clear it or choose a later time."
	else:
		status.text = tr("Connection stops at %s %s.") % [
			format_time(deadline, offset_minutes),
			zone.text,
		]


func _sync_mode() -> void:
	date_time.visible = mode.selected == AT
	duration.visible = mode.selected == AFTER
	zone.visible = mode.selected == AT


func _mode_selected(_index: int) -> void:
	_sync_mode()
	if mode.selected == AT and date_time.text.is_empty():
		date_time.text = format_time(Time.get_unix_time_from_system() + 3600.0, offset_minutes)
	_edited()


func _edited() -> void:
	_dirty = true
	apply.disabled = false
	status.text = "After counts from when you apply. Apply again to restart the duration." if mode.selected == AFTER else "Apply to save this connection's stop time."


func _apply() -> void:
	if not is_instance_valid(graph) or not graph.edges.has(edge_key):
		return
	var deadline := 0.0
	if mode.selected == AFTER:
		var parsed := parse_duration(duration.text)
		if parsed.has("error"):
			status.text = parsed.error
			return
		deadline = Time.get_unix_time_from_system() + float(parsed.result)
	elif mode.selected == AT:
		var parsed := parse_time(date_time.text, offset_minutes)
		if parsed.has("error"):
			status.text = parsed.error
			return
		deadline = float(parsed.result)
		if deadline <= Time.get_unix_time_from_system():
			status.text = "Choose a stop time in the future."
			return
	var edge: Dictionary = graph.edges[edge_key].duplicate()
	edge["stop_at"] = deadline
	_applying = true
	var outcome: Dictionary = graph.connect_nodes(edge)
	refresh()
	_applying = false
	if outcome.has("error"):
		status.text = str(outcome.error.get("message", outcome.error))
		return
	_dirty = false
	refresh()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		refresh()
