extends AcceptDialog
## Delivery history for one wire, with selected-run and new-run budgets.
const Targets := preload("res://scenes/PaneTargets.gd")
const Ports := preload("res://scenes/GraphPorts.gd")
const DEFAULT_SIZE := Vector2i(1100, 720)
var graph: Node
var edge_key := ""
var summary := Label.new()
var empty := Label.new()
var events := Tree.new()
## Selects and scrolls like a terminal.
var details := preload("res://scenes/SelectableText.gd").new()
var pending_only := CheckButton.new()
var paused := CheckButton.new()
var run_budget := HBoxContainer.new()
var run_usage_label := Label.new()
var budget_scope := OptionButton.new()
var limit_editor := LineEdit.new()
var apply_limit_button := Button.new()
var reset_count_button := Button.new()
var budget_note := Label.new()
var stop_editor := preload("res://scenes/GraphConnectionStopEditor.gd").new()
var selected_run := ""
var _budget_run := ""
var _limit_dirty := false
var _default_scope := false
var _journal: RefCounted
var _refresh_pending := false
var last_snapshot: Dictionary = {}
var rows: Array = []
var _row_ids: Array = []
var selected := ""

func _ready() -> void:
	title = "Queue Inspector"
	exclusive = false
	unresizable = false
	size = DEFAULT_SIZE
	get_ok_button().text = "Close"
	var layout := VBoxContainer.new()
	layout.size = Vector2(DEFAULT_SIZE) - Vector2(16, 60)
	layout.add_theme_constant_override("separation", 8)
	add_child(layout)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.size.x = DEFAULT_SIZE.x - 16
	layout.add_child(summary)
	pending_only.text = "Pending only"
	pending_only.toggled.connect(func(_value): refresh(true))
	# Pausing is the connection's mute: the only way to reach it by touch.
	paused.text = "Pause connection"
	paused.tooltip_text = "Paused connections do not read, send, or report turn completions. Pausing cancels pending messages; resuming applies to future messages."
	paused.toggled.connect(_pause_toggled)
	var toggles := HFlowContainer.new()
	toggles.add_theme_constant_override("h_separation", 24)
	toggles.add_child(pending_only)
	toggles.add_child(paused)
	layout.add_child(toggles)
	run_budget.add_theme_constant_override("separation", 10)
	run_usage_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	run_budget.add_child(run_usage_label)
	budget_scope.add_item("Selected run")
	budget_scope.add_item("New runs")
	budget_scope.item_selected.connect(_scope_selected)
	run_budget.add_child(budget_scope)
	var limit_label := Label.new()
	limit_label.text = "Limit"
	run_budget.add_child(limit_label)
	limit_editor.custom_minimum_size.x = 120
	limit_editor.max_length = 19
	limit_editor.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	limit_editor.text_changed.connect(_limit_edited)
	limit_editor.text_submitted.connect(func(_value): _apply_run_limit())
	run_budget.add_child(limit_editor)
	apply_limit_button.text = "Apply"
	apply_limit_button.pressed.connect(_apply_run_limit)
	run_budget.add_child(apply_limit_button)
	reset_count_button.text = "Reset count"
	reset_count_button.tooltip_text = "Reset only this run's count. Queued messages and delivery history are preserved."
	reset_count_button.pressed.connect(_reset_run_count)
	run_budget.add_child(reset_count_button)
	layout.add_child(run_budget)
	budget_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Seed wrapping widths before the first container pass; a zero-width label
	# otherwise forces the popup to grow by thousands of pixels on first open.
	budget_note.size.x = DEFAULT_SIZE.x - 16
	layout.add_child(budget_note)
	stop_editor.size.x = DEFAULT_SIZE.x - 16
	layout.add_child(stop_editor)
	stop_editor.status.size.x = DEFAULT_SIZE.x - 16
	_update_run_budget(true)
	empty.text = "No recorded deliveries on this connection yet."
	layout.add_child(empty)
	events.columns = 4
	events.hide_root = true
	events.column_titles_visible = true
	events.select_mode = Tree.SELECT_ROW
	for i in 4:
		events.set_column_title(i, ["Status", "Queued", "Updated", "Kind"][i])
		events.set_column_expand(i, true)
	events.set_column_expand_ratio(0, 2)
	var history := VSplitContainer.new()
	history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(history)
	events.custom_minimum_size.y = 80
	events.size_flags_vertical = Control.SIZE_EXPAND_FILL
	events.item_selected.connect(_select)
	history.add_child(events)
	details.custom_minimum_size.y = 80
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history.add_child(details)
	var note := Label.new()
	note.size.x = DEFAULT_SIZE.x - 16
	note.text = "Sent means handed to the receiver, not model completion. History keeps the latest 200 finished deliveries."
	note.tooltip_text = "Inspection does not consume messages. All live entries are retained, with up to 20 changes per delivery."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(note)
	visibility_changed.connect(_queue_refresh)

func inspect(target_graph: Node, key: String) -> void:
	_bind_graph(target_graph)
	edge_key = key
	stop_editor.bind_graph(graph, key)
	selected = ""
	selected_run = ""
	_default_scope = false
	_limit_dirty = false
	last_snapshot.clear()
	_sync_paused()
	popup_centered_clamped(DEFAULT_SIZE, 0.9)
	refresh(true)

func _bind_graph(target: Node) -> void:
	if graph == target: return
	_disconnect_graph()
	graph = target
	if not is_instance_valid(graph): return
	_journal = graph.queue_log
	_journal.changed.connect(_journal_changed)
	graph.changed.connect(_graph_changed)
	graph.run_usage_changed.connect(_run_usage_changed)
	graph.default_run_limit_changed.connect(_default_run_limit_changed)
	graph.tree_exiting.connect(_graph_exiting)

func _disconnect_graph() -> void:
	if is_instance_valid(_journal) and _journal.changed.is_connected(_journal_changed):
		_journal.changed.disconnect(_journal_changed)
	_journal = null
	if is_instance_valid(graph):
		if graph.changed.is_connected(_graph_changed): graph.changed.disconnect(_graph_changed)
		if graph.run_usage_changed.is_connected(_run_usage_changed): graph.run_usage_changed.disconnect(_run_usage_changed)
		if graph.default_run_limit_changed.is_connected(_default_run_limit_changed): graph.default_run_limit_changed.disconnect(_default_run_limit_changed)
		if graph.tree_exiting.is_connected(_graph_exiting): graph.tree_exiting.disconnect(_graph_exiting)

func _exit_tree() -> void:
	_disconnect_graph()

func _graph_exiting() -> void:
	_disconnect_graph()
	graph = null
	_queue_refresh()

func _journal_changed(edge: String) -> void:
	if edge == edge_key: _queue_refresh()

func _graph_changed() -> void:
	# Connection removal/renaming changes the heading, not journal contents.
	if visible and not last_snapshot.is_empty() and is_instance_valid(graph):
		_update_summary(last_snapshot)
	_sync_paused()

func _sync_paused() -> void:
	var edge: Dictionary = graph.edges.get(edge_key, {}) if is_instance_valid(graph) else {}
	paused.disabled = edge.is_empty()
	paused.set_pressed_no_signal(bool(edge.get("muted", false)))

func _pause_toggled(value: bool) -> void:
	if not is_instance_valid(graph) or not graph.edges.has(edge_key):
		_sync_paused()
		return
	var edge: Dictionary = graph.edges[edge_key].duplicate()
	edge.muted = value
	var result: Dictionary = graph.connect_nodes(edge)
	if result.has("error"): budget_note.text = str(result.error.get("message", result.error))
	_sync_paused()

func _run_usage_changed(run_id: String) -> void:
	if visible and selected_run == run_id:
		_update_run_budget()

func _default_run_limit_changed() -> void:
	if visible and _editing_default(): _update_run_budget()

func _editing_default() -> bool:
	return _default_scope or selected_run.is_empty()

func _scope_selected(index: int) -> void:
	_default_scope = index == 1
	_update_run_budget(true)

func _edited_limit() -> int:
	var text := limit_editor.text.strip_edges()
	if not text.is_valid_int(): return 0
	var limit := text.to_int()
	# Detect overflow as well as zero/negative values; retain exact integer limits.
	if limit <= 0 or str(limit) != text.trim_prefix("+").lstrip("0"): return 0
	return limit

func _limit_edited(_text: String) -> void:
	# Keep edits to this field as a draft for new runs in the current scope.
	# A first delivery can arrive mid-edit and must leave the draft's target alone.
	if _editing_default(): _default_scope = true
	_limit_dirty = true
	_update_run_budget()

func _update_run_budget(force_editor := false) -> void:
	var defaults := _editing_default()
	var usage := preload("res://scenes/AgentGraph.gd").RunUsage.new()
	if is_instance_valid(graph):
		usage = graph.default_run_usage(edge_key) if defaults else graph.run_usage(selected_run, edge_key)
	var available: bool = usage.available
	run_usage_label.text = tr("Messages queued %d/%d") % [usage.count, usage.limit]
	run_usage_label.tooltip_text = "Starting budget for new runs across all connections." if defaults else "Total accepted messages across every connection in the selected run."
	budget_scope.select(1 if defaults else 0)
	budget_scope.set_item_disabled(0, selected_run.is_empty())
	budget_scope.disabled = not is_instance_valid(graph)
	budget_scope.tooltip_text = tr("New runs sets the default across all connections. Selected run: %s") % selected_run if not selected_run.is_empty() else "Set the default before the first message is queued."
	var scope_key := "" if defaults else selected_run
	if force_editor or _budget_run != scope_key or not _limit_dirty or not available:
		limit_editor.text = str(usage.limit)
		_limit_dirty = false
	_budget_run = scope_key
	limit_editor.editable = available
	apply_limit_button.disabled = not available or _edited_limit() <= 0
	reset_count_button.disabled = defaults or not available or int(usage.count) == 0
	if not available:
		budget_note.text = "This run is no longer available. Choose New runs to set the default." if is_instance_valid(graph) else "Graph is no longer available."
	elif _edited_limit() <= 0:
		budget_note.text = "Enter a positive whole-number limit."
	elif defaults:
		budget_note.text = "Default for new runs across all connections. Existing runs keep their limits."
	else:
		budget_note.text = tr("Run %s spans connections. Reset preserves queued messages and history.") % selected_run.left(12)

func _apply_run_limit() -> void:
	if not is_instance_valid(graph) or _edited_limit() <= 0: return
	var result: Dictionary = await graph.set_default_run_limit(_edited_limit(), edge_key) if _editing_default() else await graph.set_run_limit(selected_run, _edited_limit(), edge_key)
	if result.has("error"):
		budget_note.text = str(result.error.message)
		return
	_update_run_budget(true)

func _reset_run_count() -> void:
	if not is_instance_valid(graph) or _editing_default(): return
	var result: Dictionary = await graph.reset_run_count(selected_run, edge_key)
	if result.has("error"):
		budget_note.text = str(result.error.message)
		return
	_update_run_budget()

func _queue_refresh() -> void:
	if not visible or _refresh_pending: return
	_refresh_pending = true
	_flush_refresh.call_deferred()

func _flush_refresh() -> void:
	if not _refresh_pending: return
	_refresh_pending = false
	if visible: refresh()

static func clock(value: Variant, full := false) -> String:
	var seconds := float(value)
	var text := Time.get_datetime_string_from_unix_time(int(seconds), true)
	return (text if full else text.substr(11)) + " UTC"

static func status_text(row: Dictionary) -> String:
	var status := str(row.status)
	var label := status_label(status)
	if status.begins_with("failed") or status.begins_with("cancel failed"): return "[!] " + label
	if status.begins_with("cancelled"): return "[-] " + label
	if row.pending: return ("[ ] " if status == "queued in Graffitty" else "[~] ") + label
	if status in ["sent to receiver", "submitted", "delivered"]: return "[x] " + label
	return "[?] " + label

static func status_label(status: String) -> String:
	for prefix in ["failed: ", "cancel failed: ", "cancelled: "]:
		if status.begins_with(prefix):
			return String(TranslationServer.translate(prefix + "%s")) % String(TranslationServer.translate(status.trim_prefix(prefix)))
	return String(TranslationServer.translate(status))

func refresh(force := false) -> void:
	_refresh_pending = false
	if not is_instance_valid(graph):
		summary.text = "Graph is no longer available."
		selected_run = ""
		_update_run_budget(true)
		return
	var snapshot: Dictionary = graph.queue_log.snapshot(edge_key)
	_update_summary(snapshot)
	_update_run_budget()
	if not force and snapshot == last_snapshot: return
	last_snapshot = snapshot
	rows = snapshot.events.filter(func(row): return not pending_only.button_pressed or row.pending)
	empty.visible = rows.is_empty()
	empty.text = "No pending messages." if pending_only.button_pressed else "No recorded deliveries on this connection yet."
	var ids := rows.map(func(row): return row.event_id)
	var rebuild := ids != _row_ids or events.get_root() == null
	if rebuild:
		events.clear()
		events.create_item()
		_row_ids = ids
	var root := events.get_root()
	var existing := root.get_first_child()
	var chosen: TreeItem
	for row in rows:
		var item := events.create_item(root) if rebuild else existing
		if not rebuild: existing = existing.get_next()
		item.set_metadata(0, row.event_id)
		item.set_text(0, status_text(row))
		item.set_text(1, clock(row.queued_at))
		item.set_text(2, clock(row.updated_at))
		item.set_text(3, str(row.kind))
		item.set_tooltip_text(0, status_text(row))
		var color := Color("e6be74") if row.pending else Color("aab2bf")
		if status_text(row).begins_with("[x]"): color = Color("89ddbd")
		if status_text(row).begins_with("[!]"): color = Color("f07178")
		item.set_custom_color(0, color)
		if row.event_id == selected: chosen = item
	if chosen == null: chosen = root.get_first_child()
	if chosen != null:
		chosen.select(0)
		_select()
	else:
		selected = ""
		selected_run = ""
		_update_run_budget(true)
		details.text = "Select a delivery to see its timestamped history."

func _update_summary(snapshot: Dictionary) -> void:
	var connected: bool = graph.edges.has(edge_key)
	var from := edge_key.get_slice(">", 0)
	var to := edge_key.get_slice(">", 1)
	summary.text = tr("%s / %s → %s / %s\n%d pending · %d recorded%s%s") % [Targets.label(Ports.node_id(from)), Ports.port_id(from), Targets.label(Ports.node_id(to)), Ports.port_id(to), snapshot.pending, snapshot.events.size(), tr(" · connection removed") if not connected else "", tr(" · %d omitted") % snapshot.omitted if snapshot.omitted > 0 else ""]

func _select() -> void:
	var item := events.get_selected()
	if item == null: return
	selected = str(item.get_metadata(0))
	for row in rows:
		if row.event_id != selected: continue
		selected_run = str(row.get("run_id", ""))
		_update_run_budget()
		details.text = tr("%s\n\nTimeline\n") % status_text(row)
		for change in row.transitions:
			details.text += "%s  %s\n" % [clock(change.at, true), status_label(str(change.status))]
		details.text += tr("\nRun: %s\nEvent: %s\nQueued: %s\nUpdated: %s") % [selected_run, row.event_id, clock(row.queued_at, true), clock(row.updated_at, true)]
		return

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		refresh(true)
