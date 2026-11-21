extends Control
## Dock geometry is shared by preview and commit; native floating windows own
## content. Left and right are columns of stacked panels.
##
## Top and bottom are bands: rows of side-by-side panels, one row above
## another, each row with its own height.
const Paths := preload("res://graffitty/paths.gd")
const MIN_CENTER := 320.0
const MIN_PANEL := 40.0
const COLLAPSED_WIDTH := 44.0
const MIN_HEIGHT := 100.0
## Band rows shrink to one status-strip row; below the old minimum they are compact.
const MIN_BAND_HEIGHT := 32.0
const COMPACT_BAND_HEIGHT := 100.0
const COMPACT_WIDTH := 80.0
const DEFAULT_ROW_HEIGHT := 160.0
## A panel's magnification, saved with its placement.
const MIN_SCALE := 0.5
const MAX_SCALE := 3.0
## Dock documents name panels by these keys; user panels use `panel:<folder>`.
const PANEL_KEYS := ["agents", "sessions", "pane_status", "resource_monitor", "status_line", "messages", "notifications"]
var panels: Array[Control] = []
var widths := {"left": 300.0, "right": 300.0}
var preview := PanelContainer.new()
var _preview_layout := VBoxContainer.new()
var _preview_header: Control
var _reserved := Vector4.ZERO # left, right, top, bottom
## Row heights per band, outermost row first.
var band_rows := {"top": [], "bottom": []}
var _hosts: Array[WeakRef] = []
var expanded_widths := {"left": 300.0, "right": 300.0}
var state_path := Paths.stdpath("state").path_join("list-docks.json")
var _saved: Dictionary = {}
var _candidate: Dictionary = {}
var _preview_source: Control
var _preview_content: Control
var _touches := {}
var workspace_active := true
var panels_hidden := false
var _reflow_pending := false
var _mobile_resize := preload("res://scenes/MobileDockResize.gd").new()

func center_minimum() -> float:
	return 120.0 if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else MIN_CENTER

func touch_active() -> bool: return not _touches.is_empty()

func pointer() -> Vector2:
	return _touches.values()[0] if not _touches.is_empty() else get_global_mouse_position()

func _window_input(event: InputEvent) -> void:
	# Window signals precede Viewport's physical-to-logical conversion. Never
	# mix these coordinates with _input (which is already converted).
	_input(event.xformed_by(get_window().get_final_transform().affine_inverse()))

func _input(event: InputEvent) -> void:
	if not workspace_active or panels_hidden: return
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled: _touches[event.index] = event.position
		else: _touches.erase(event.index)
	elif event is InputEventScreenDrag and _touches.has(event.index):
		_touches[event.index] = event.position
	# An existing gesture keeps ownership across previews and window boundaries.
	for panel in panels:
		if is_instance_valid(panel.dialog) and panel.dialog._title_pressed and panel.dialog.floating_title_input(event):
			get_window().set_input_as_handled()
			return
	if is_instance_valid(_mobile_resize.window) and _mobile_resize.handle(event, panels):
		get_window().set_input_as_handled()
		return
	var targets := panels
	var press: bool = (event is InputEventScreenTouch or event is InputEventMouseButton) and event.pressed
	if press:
		# The embedder stores windows in drawing order. A panel body or popup
		# covering another title must block presses on that title underneath it.
		var windows := get_window().get_embedded_subwindows()
		windows.reverse()
		for window in windows:
			if window.visible and Rect2(Vector2(window.position), Vector2(window.size)).has_point(event.position):
				targets = panels.filter(func(panel): return panel.dialog == window)
				if targets.is_empty(): return
				break
	for panel in targets:
		if is_instance_valid(panel.dialog) and panel.dialog.floating_title_input(event):
			get_window().set_input_as_handled()
			return
	if (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE) or (event is InputEventScreenTouch and event.canceled):
		for panel in panels:
			if is_instance_valid(panel.dialog): panel.dialog.cancel_native_drag()
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls() and _mobile_resize.handle(event, targets):
		get_window().set_input_as_handled()

func set_workspace_active(active: bool) -> void:
	workspace_active = active
	visible = active and not panels_hidden
	if not visible:
		_mobile_resize.cancel()
		_touches.clear()
		show_preview({})
		_reserve(Vector4.ZERO)
	else: reflow()

## Temporary visibility only: keep panel instances, docking and saved layout intact.
func toggle_panels() -> void:
	set_panels_hidden(not panels_hidden)

func set_panels_hidden(hidden: bool) -> void:
	if panels_hidden == hidden: return
	panels_hidden = hidden
	var window := get_window()
	window.set_meta(&"side_panels_hidden", hidden)
	for panel in get_tree().get_nodes_in_group(&"workspace_tool_windows"):
		if panel.get_parent().get_window() == window:
			panel.set_workspace_active(workspace_active)
	set_workspace_active(workspace_active)

static func for_window(window: Window) -> Control:
	if window.has_meta(&"list_dock_space"): return window.get_meta(&"list_dock_space")
	var layer: CanvasLayer = preload("res://scenes/WorkspaceLayers.gd").for_window(window).create_layer(preload("res://scenes/WorkspaceLayers.gd").Order.DOCK, true)
	var space: Control = load("res://scenes/ListDockSpace.gd").new()
	layer.add_child(space)
	window.set_meta(&"list_dock_space", space)
	return space

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_to_group(&"touch_chrome")
	preview.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	var style := StyleBoxFlat.new()
	style.bg_color = Color("202126")
	style.border_color = Color(1, 1, 1, .2)
	style.set_border_width_all(0 if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else 2)
	style.set_corner_radius_all(6)
	preview.add_theme_stylebox_override("panel", style)
	_preview_layout.add_theme_constant_override("separation", 0)
	preview.add_child(_preview_layout)
	preview.minimum_size_changed.connect(_fit_preview)
	add_child(preview)
	preview.hide()
	load_layout()
	get_window().size_changed.connect(reflow)
	# Own embedded gestures before the viewport routes mouse input to subwindows.
	set_process_input(false)
	get_window().window_input.connect(_window_input)
	set_workspace_active(get_window().get_meta(&"workspace_ui_active", true))

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_mobile_resize.cancel()
		for panel in panels:
			if is_instance_valid(panel.dialog): panel.dialog.cancel_native_drag()

func add_panel(panel: Control) -> void:
	panels.append(panel)
	add_child(panel)
	panel.minimum_size_changed.connect(queue_reflow)
	queue_reflow()

func remove_panel(panel: Control) -> void:
	panels.erase(panel)
	if panel.side in ["top", "bottom"]: _compact_rows(panel.side)
	show_preview({})
	queue_reflow()

func _window_hosts() -> Array:
	var app := get_node_or_null("/root/TerminalApplication")
	if app == null: return []
	return app.hosts.filter(func(h): return is_instance_valid(h) and h.get_window() == get_window() and is_instance_valid(h.layout_root))

func bounds() -> Rect2:
	var top := 0.0
	var bottom := 0.0
	for host in _window_hosts():
		top = maxf(top, host.layout_root.offset_top)
		bottom = maxf(bottom, -host.layout_root.offset_bottom)
		if is_instance_valid(host.workspace_view):
			for chrome in [host.workspace_view.tab_bar, host.workspace_view.toolbar]:
				if is_instance_valid(chrome) and chrome.is_visible_in_tree(): top = maxf(top, chrome.get_global_rect().end.y)
	return Rect2(Vector2(0, top), (Vector2(get_window().get_visible_rect().size) - Vector2(0, top + bottom)).max(Vector2.ONE))

func screen_to_local(point: Vector2) -> Vector2:
	return preload("res://scenes/ScreenSpace.gd").into(self, point)

func local_to_screen(point: Vector2) -> Vector2:
	return preload("res://scenes/ScreenSpace.gd").of(self, point)

func column(side: String, excluding: Control = null) -> Array:
	return panels.filter(func(p): return p != excluding and is_instance_valid(p.dialog) and not p.dialog.is_queued_for_deletion() and p.side == side)

## A band's panels grouped by row, outermost row first, in dock order.
func rows_of(side: String, excluding: Control = null) -> Array:
	var result: Array = []
	for panel in column(side, excluding):
		while result.size() <= panel.row: result.append([])
		result[panel.row].append(panel)
	return result.filter(func(row): return not row.is_empty())

func queue_reflow() -> void:
	if _reflow_pending or not is_inside_tree(): return
	_reflow_pending = true
	_flush_reflow.call_deferred()

func _flush_reflow() -> void:
	if not _reflow_pending: return
	reflow()

func watch_layout(host: Node) -> void:
	if not is_instance_valid(host.workspace_view): return
	for control in [host.layout_root, host.workspace_view.tab_bar, host.workspace_view.toolbar]:
		if not is_instance_valid(control): continue
		if not control.resized.is_connected(queue_reflow): control.resized.connect(queue_reflow)
		if not control.visibility_changed.is_connected(queue_reflow): control.visibility_changed.connect(queue_reflow)


func gap() -> float:
	for host in _window_hosts():
		if host.layout_root.is_visible_in_tree():
			return clampf(float(host.tiling_config.gap), 0, 128)
	return 0.0

func stack_minimum(count: int) -> float:
	return count * MIN_HEIGHT + maxi(0, count - 1) * gap()

func stack_flexible(count: int) -> float:
	return maxf(0, bounds().size.y - 2 * gap() - stack_minimum(count))

func width_limit(side: String) -> float:
	var other := "right" if side == "left" else "left"
	var count := 1 + int(not column(other).is_empty())
	return maxf(MIN_PANEL, bounds().size.x - center_minimum() - count * gap() - (count - 1) * MIN_PANEL)

func _column_rect(side: String, left: Array, right: Array) -> Rect2:
	var rect := bounds()
	var spacing := gap()
	var count := int(not left.is_empty()) + int(not right.is_empty())
	# Existing docks take priority over the preferred center width. Resizing
	# the app must never change panel ownership or persisted placement.
	var available := maxf(count * MIN_PANEL, rect.size.x - center_minimum() - count * spacing)
	var l := clampf(widths.left, MIN_PANEL, available - (MIN_PANEL if not right.is_empty() else 0)) if not left.is_empty() else 0.0
	var r := clampf(widths.right, MIN_PANEL, available - l) if not right.is_empty() else 0.0
	return Rect2(Vector2(rect.position.x + spacing if side == "left" else rect.end.x - spacing - r, rect.position.y + spacing), Vector2(l if side == "left" else r, maxf(0, rect.size.y - 2 * spacing)))

static func compact_for(side: String, extent: Vector2) -> bool:
	return extent.x < COMPACT_WIDTH or (side in ["top", "bottom"] and extent.y < COMPACT_BAND_HEIGHT)

## Heights the given band may use in total, leaving the other band and the terminal their minimum.
func band_height_limit(side: String, other_rows: Array = []) -> float:
	var other := "bottom" if side == "top" else "top"
	var taken := _rows_total(other_rows if not other_rows.is_empty() else heights_of(other))
	return bounds().size.y - 2 * gap() - MIN_HEIGHT - (taken + gap() if taken > 0 else 0.0)

## The stored heights for a band's rows, defaulting new rows.
##
## Heights are looked up by each row's own index, so a band whose middle row
## left still renders its remaining rows at their own heights.
func heights_of(side: String, rows: Array = []) -> Array:
	if rows.is_empty(): rows = rows_of(side)
	var stored: Array = band_rows.get(side, [])
	var result: Array = []
	for row in rows:
		var index: int = row[0].row if row is Array and not row.is_empty() else result.size()
		var bar := bar_height(row) if row is Array else 0.0
		result.append(bar if bar > 0.0 else (float(stored[index]) if index < stored.size() else DEFAULT_ROW_HEIGHT))
	return result

## A row holding only bars is exactly as tall as the tallest bar at its
## magnification: never dragged taller or shorter. 0 for any other row.
func bar_height(row: Array) -> float:
	var height := 0.0
	for panel in row:
		if not is_instance_valid(panel.dialog) or not panel.dialog.dock_only(): return 0.0
		var preferred: Vector2i = panel.dialog.get_meta(&"preferred_size", Vector2i.ZERO)
		height = maxf(height, (float(preferred.y) if preferred.y > 0 else MIN_BAND_HEIGHT) * panel.dialog.layout_scale())
	return roundf(height)

## Renumbers a band's rows after one emptied, keeping each remaining row's height.
func _compact_rows(side: String) -> void:
	var stored: Array = band_rows.get(side, [])
	var remaining := column(side)
	var used := {}
	for panel in remaining: used[panel.row] = true
	var indices := used.keys()
	indices.sort()
	var kept: Array = []
	for position in indices.size():
		var index: int = indices[position]
		kept.append(float(stored[index]) if index < stored.size() else DEFAULT_ROW_HEIGHT)
		for panel in remaining:
			if panel.row == index: panel.row = position
	band_rows[side] = kept

func _rows_total(heights: Array) -> float:
	var total := 0.0
	for height in heights: total += float(height)
	return total + maxi(0, heights.size() - 1) * gap()

## Row heights clamped so the band fits above the terminal's minimum.
func _fit_heights(side: String, heights: Array, other_rows: Array = []) -> Array:
	var limit := band_height_limit(side, other_rows)
	# A bar smaller than one status row keeps its own height as its floor.
	var floors: Array = heights.map(func(h): return minf(MIN_BAND_HEIGHT, float(h)))
	var fitted: Array = heights.map(func(h): return float(h))
	var excess := _rows_total(fitted) - limit
	# Shrink from the terminal-facing row inward, never below one status row.
	var order := range(fitted.size() - 1, -1, -1) if side == "top" else range(fitted.size())
	for index in order:
		if excess <= 0: break
		var give := minf(excess, fitted[index] - floors[index])
		fitted[index] -= give
		excess -= give
	return fitted

func _band_span(left: Array, right: Array) -> Vector2:
	var area := bounds()
	var l := _column_rect("left", left, right)
	var r := _column_rect("right", left, right)
	var start := (l.end.x if not left.is_empty() else area.position.x) + gap()
	var end := (r.position.x if not right.is_empty() else area.end.x) - gap()
	return Vector2(start, maxf(0, end - start))

## Rects per row of a band, outermost first, given its heights.
func _row_rects(side: String, heights: Array, left: Array, right: Array) -> Array:
	var area := bounds()
	var span := _band_span(left, right)
	var rects: Array = []
	var y := area.position.y + gap() if side == "top" else area.end.y - gap() - _rows_total(heights)
	for height in heights:
		rects.append(Rect2(Vector2(span.x, y), Vector2(span.y, float(height))))
		y += float(height) + gap()
	return rects

## Side-by-side cells inside one row, by weight.
func row_cells(items: Array, weights: Array, rect: Rect2) -> Array[Rect2]:
	var total := 0.0
	for weight in weights: total += maxf(0.001, weight)
	var result: Array[Rect2] = []
	var x := rect.position.x
	var flexible := maxf(0, rect.size.x - items.size() * MIN_PANEL - maxi(0, items.size() - 1) * gap())
	for index in items.size():
		var w := MIN_PANEL + flexible * maxf(0.001, weights[index]) / total
		result.append(Rect2(Vector2(x, rect.position.y), Vector2(w, rect.size.y)))
		x += w + gap()
	return result

func cells(items: Array, weights: Array, rect: Rect2) -> Array[Rect2]:
	var total := 0.0
	var minimum := maxi(0, items.size() - 1) * gap()
	for index in items.size():
		var folded: bool = items[index].dialog.folded
		minimum += MIN_BAND_HEIGHT if folded else MIN_HEIGHT
		if not folded: total += maxf(0.001, weights[index])
	var result: Array[Rect2] = []
	var y := rect.position.y
	var flexible := maxf(0, rect.size.y - minimum)
	for index in items.size():
		var h: float = MIN_BAND_HEIGHT if items[index].dialog.folded else MIN_HEIGHT + flexible * maxf(0.001, weights[index]) / maxf(total, 0.001)
		result.append(Rect2(Vector2(rect.position.x, y), Vector2(rect.size.x, h)))
		y += h + gap()
	return result

func _preferred_row_height(panel: Control) -> float:
	if panel.dialog.dock_only() and panel.side in ["top", "bottom"]:
		var heights: Array = band_rows[panel.side]
		if panel.row < heights.size(): return float(heights[panel.row])
	var preferred: Vector2i = panel.dialog.get_meta(&"preferred_size", Vector2i.ZERO) if is_instance_valid(panel.dialog) else Vector2i.ZERO
	return float(preferred.y) if preferred.y > 0 else DEFAULT_ROW_HEIGHT

func _plan_band(panel: Control, pointer: Vector2, side: String, left: Array, right: Array, forced: bool) -> Dictionary:
	var area := bounds()
	var rows := rows_of(side, panel)
	var heights := heights_of(side, rows) if not rows.is_empty() else []
	var other := rows_of("bottom" if side == "top" else "top", panel)
	var span := _band_span(left, right)
	var reach := 56.0 if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else 32.0
	var occupied := _rows_total(heights)
	var near := pointer.y <= area.position.y + gap() + occupied + reach if side == "top" else pointer.y >= area.end.y - gap() - occupied - reach
	if not forced and (pointer.x < span.x or pointer.x > span.x + span.y or not near): return {}
	if span.y < MIN_PANEL: return {}
	if rows.is_empty():
		var height := _fit_heights(side, [_preferred_row_height(panel)], heights_of("bottom" if side == "top" else "top", other))
		if height[0] < MIN_BAND_HEIGHT or band_height_limit(side, heights_of("bottom" if side == "top" else "top", other)) < MIN_BAND_HEIGHT: return {}
		var rect: Rect2 = _row_rects(side, height, left, right)[0]
		return {"panel": panel, "side": side, "rows": [[panel]], "weights": [[1.0]], "heights": height, "row": 0, "rect": rect}
	var rects := _row_rects(side, heights, left, right)
	var weights: Array = rows.map(func(row): return row.map(func(p): return p.weight))
	# A new row above the outermost or below the innermost row, else into the row under the pointer.
	var row_index := -1
	var edge := 10.0
	if pointer.y < rects[0].position.y + edge: row_index = 0
	elif pointer.y > rects[rects.size() - 1].end.y - edge: row_index = rows.size()
	var new_row := row_index >= 0
	if new_row:
		if band_height_limit(side, heights_of("bottom" if side == "top" else "top", other)) - _rows_total(heights) - gap() < MIN_BAND_HEIGHT: return {}
		rows.insert(row_index, [panel])
		weights.insert(row_index, [1.0])
		heights.insert(row_index, _preferred_row_height(panel))
	else:
		for index in rects.size():
			if pointer.y <= rects[index].end.y + gap() / 2.0 or index == rects.size() - 1:
				row_index = index
				break
		var row: Array = rows[row_index]
		var cell_rects := row_cells(row, weights[row_index], rects[row_index])
		var at := row.size()
		for index in row.size():
			if pointer.x < cell_rects[index].get_center().x:
				at = index
				break
		var incoming: float = panel.weight if panel.side == side and panel.row == row_index else weights[row_index][mini(at, row.size() - 1)] / 2.0
		if panel.side != side or panel.row != row_index: weights[row_index][mini(at, row.size() - 1)] = incoming
		row.insert(at, panel)
		weights[row_index].insert(at, incoming)
		if rects[row_index].size.x < (row.size()) * MIN_PANEL + (row.size() - 1) * gap(): return {}
	heights = _fit_heights(side, heights, heights_of("bottom" if side == "top" else "top", other))
	var final_rects := _row_rects(side, heights, left, right)
	var target_cells := row_cells(rows[row_index], weights[row_index], final_rects[row_index])
	var rect: Rect2 = target_cells[rows[row_index].find(panel)]
	return {"panel": panel, "side": side, "rows": rows, "weights": weights, "heights": heights, "row": row_index, "rect": rect}

func plan(panel: Control, pointer: Vector2, forced_side := "") -> Dictionary:
	var area := bounds()
	if not area.grow(12).has_point(pointer) and forced_side.is_empty(): return {}
	var left := column("left", panel)
	var right := column("right", panel)
	for edge in ["top", "bottom"]:
		if edge not in panel.dialog.dock_sides(): continue
		if not forced_side.is_empty() and forced_side != edge: continue
		var candidate := _plan_band(panel, pointer, edge, left, right, forced_side == edge)
		if not candidate.is_empty(): return candidate
		if forced_side == edge: return {}
	var side := forced_side
	if side.is_empty():
		for edge in ["left", "right"]:
			var occupants := column(edge, panel)
			var reach: float = widths[edge] + gap() if not occupants.is_empty() else (56.0 if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else 32.0)
			if (pointer.x <= area.position.x + reach if edge == "left" else pointer.x >= area.end.x - reach): side = edge; break
	if side not in panel.dialog.dock_sides(): return {}
	var items := column(side, panel)
	var opposite := column("right" if side == "left" else "left", panel)
	if area.size.x < center_minimum() + (MIN_PANEL + gap()) * (1 + int(not opposite.is_empty())) or area.size.y < 2 * gap() + stack_minimum(items.size() + 1): return {}
	var index := items.size()
	# Hit-test the settled column, not positions changed by the last preview.
	var settled_rect := _column_rect(side, items if side == "left" else opposite, items if side == "right" else opposite)
	var settled := cells(items, items.map(func(p): return p.weight), settled_rect)
	for i in items.size():
		if pointer.y < settled[i].get_center().y: index = i; break
	var weights := items.map(func(p): return p.weight)
	var incoming: float = panel.weight
	if panel.side != side:
		if items.is_empty(): incoming = 1.0
		else:
			var split := mini(index, items.size() - 1)
			incoming = weights[split] / 2.0
			weights[split] = incoming
	items.insert(index, panel)
	weights.insert(index, incoming)
	var rect := _column_rect(side, items if side == "left" else opposite, items if side == "right" else opposite)
	var placements := cells(items, weights, rect)
	return {"panel": panel, "side": side, "items": items, "weights": weights, "rect": placements[index]}

## Docks a panel without a drag: bands get their own row next to the terminal,
## pushing existing rows outward; columns append below their current panels.
func dock_default(panel: Control, side: String) -> bool:
	if side.is_empty() or side not in panel.dialog.dock_sides(): return false
	var name: String = str(panel.dialog.get("mod_name")) if panel.dialog.get("mod_name") != null else ""
	var spec := preload("res://scenes/mods/ModService.gd").manifest(name)
	var after: String = spec.get("after", "")
	var candidate := {}
	if side in ["top", "bottom"]:
		var left := column("left", panel)
		var right := column("right", panel)
		var rows := rows_of(side, panel)
		var heights := heights_of(side, rows) if not rows.is_empty() else []
		var other_side := "bottom" if side == "top" else "top"
		var other := heights_of(other_side, rows_of(other_side, panel))
		if not panel.dialog.dock_only():
			if _band_span(left, right).y < MIN_PANEL: return false
			if band_height_limit(side, other) - _rows_total(heights) - (gap() if not rows.is_empty() else 0.0) < MIN_BAND_HEIGHT: return false
		var weights: Array = rows.map(func(row): return row.map(func(p): return p.weight))
		# Rows are listed top to bottom, so the terminal-facing row is the last
		# one in the top band and the first one in the bottom band.
		var inner: bool = panel.dialog.default_dock_row() != "outer"
		var index := (0 if inner else rows.size()) if side == "bottom" else (rows.size() if inner else 0)
		if not after.is_empty():
			for target in column(side, panel):
				if target.dialog.get("mod_name") == after: index = target.row + 1
		rows.insert(index, [panel])
		weights.insert(index, [1.0])
		heights.insert(index, _preferred_row_height(panel))
		heights = _fit_heights(side, heights, other)
		candidate = {"panel": panel, "side": side, "rows": rows, "weights": weights, "heights": heights, "row": index, "rect": _row_rects(side, heights, left, right)[index]}
	else:
		# A sidebar starts as its compact rail; the configured size is the
		# width it expands to.
		if column(side, panel).is_empty():
			if spec.has("size"): expanded_widths[side] = clampf(float(spec.size), MIN_PANEL, width_limit(side))
			widths[side] = COLLAPSED_WIDTH * panel.dialog.layout_scale()
		candidate = plan(panel, bounds().end, side)
	if candidate.is_empty(): return false
	commit(panel, candidate)
	if not after.is_empty() and side in ["left", "right"]:
		for target in panels:
			if target != panel and target.side == side and target.dialog.get("mod_name") == after:
				panels.erase(panel)
				panels.insert(panels.find(target) + 1, panel)
				break
		reflow()
		save_layout()
	return true

func show_preview(candidate: Dictionary) -> void:
	var source: Control = candidate.get("panel")
	if source != _preview_source:
		if is_instance_valid(_preview_source) and is_instance_valid(_preview_source.dialog):
			var previous: Control = _preview_source
			var destination: Node = previous.dialog if previous.side.is_empty() else previous.slot
			if is_instance_valid(_preview_header):
				var layout: Node = previous.slot.get_parent()
				_preview_header.reparent(layout)
				layout.move_child(_preview_header, 0)
			if is_instance_valid(_preview_content) and _preview_content.get_parent() == _preview_layout:
				_preview_content.reparent(destination)
				_preview_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			previous.dialog.set_dock_preview(false)
		_preview_source = source
		_preview_content = null
		_preview_header = null
	_candidate = candidate
	preview.visible = not candidate.is_empty()
	if candidate.is_empty():
		reflow()
		return
	var compact: bool = source.dialog.dock_only() or compact_for(candidate.side, candidate.rect.size / source.dialog.layout_scale())
	source.dialog.set_compact(compact, compact and candidate.side in ["top", "bottom"])
	if _preview_content == null:
		preview.add_theme_stylebox_override("panel", source.get_theme_stylebox("panel").duplicate())
		# Move the live controls, not a duplicate. Updates keep running during drag.
		_preview_header = source._header
		_preview_header.reparent(_preview_layout)
		_preview_content = source.dialog._body
		_preview_content.reparent(_preview_layout)
		_preview_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		source.dialog.set_dock_preview(true)
	move_child(preview, get_child_count() - 1)
	reflow()
	_preview_header.visible = not compact
	# Use the destination's chrome so title/content geometry agrees on drop.
	var chrome := preview.get_theme_stylebox("panel") as StyleBoxFlat
	chrome.content_margin_left = 0 if candidate.rect.size.x < COMPACT_WIDTH * source.dialog.layout_scale() else 4
	chrome.content_margin_right = chrome.content_margin_left
	_fit_preview()

func _fit_preview() -> void:
	if _candidate.is_empty(): return
	# Container minimum sizes update asynchronously after compact content changes.
	# Reapply the same live plan once that update lands; never retain the expanded size.
	preview.position = _candidate.rect.position
	preview.size = _candidate.rect.size

func commit(panel: Control, candidate: Dictionary) -> void:
	if candidate.is_empty(): return
	var previous: String = panel.side
	panel.side = candidate.side
	if candidate.has("rows"):
		# Preserve every row's order and proportions, and the planned heights.
		var ordered: Array = []
		for row_index in candidate.rows.size():
			for index in candidate.rows[row_index].size():
				var item: Control = candidate.rows[row_index][index]
				item.row = row_index
				item.weight = candidate.weights[row_index][index]
				ordered.append(item)
		for item in ordered: panels.erase(item)
		for item in ordered: panels.append(item)
		band_rows[candidate.side] = candidate.heights.duplicate()
	else:
		panel.row = 0
		# Preserve the other column and the exact planned order/proportions.
		for item in candidate.items: panels.erase(item)
		for index in candidate.items.size():
			var item: Control = candidate.items[index]
			item.weight = candidate.weights[index]
			panels.append(item)
	if previous in ["top", "bottom"] and previous != candidate.side: _compact_rows(previous)
	panel.dialog.attach_to_dock()
	show_preview({})
	reflow()
	save_layout()

func reflow() -> void:
	_reflow_pending = false
	if not is_inside_tree() or not workspace_active or panels_hidden: return
	for host in _window_hosts(): watch_layout(host)
	var left := column("left")
	var right := column("right")
	var bands := {"top": rows_of("top"), "bottom": rows_of("bottom")}
	var band_weights := {"top": [], "bottom": []}
	var band_heights := {"top": heights_of("top"), "bottom": heights_of("bottom")}
	for edge in bands: band_weights[edge] = bands[edge].map(func(row): return row.map(func(p): return p.weight))
	if not _candidate.is_empty():
		left.erase(_candidate.panel)
		right.erase(_candidate.panel)
		for edge in bands:
			bands[edge] = rows_of(edge, _candidate.panel)
			band_heights[edge] = heights_of(edge, bands[edge])
			band_weights[edge] = bands[edge].map(func(row): return row.map(func(p): return p.weight))
		match _candidate.side:
			"left": left = _candidate.items
			"right": right = _candidate.items
			"top", "bottom":
				bands[_candidate.side] = _candidate.rows
				band_weights[_candidate.side] = _candidate.weights
				band_heights[_candidate.side] = _candidate.heights
	var l := _column_rect("left", left, right)
	var r := _column_rect("right", left, right)
	for pair in [[left, l, "left"], [right, r, "right"]]:
		var items: Array = pair[0]
		var weights := items.map(func(p): return p.weight)
		# Only a column candidate carries flat `items`/`weights`; a band candidate
		# has rows, and must not be matched against an empty column by `[] == []`.
		if _candidate.has("items") and _candidate.items == items: weights = _candidate.weights
		var placements := cells(items, weights, pair[1])
		for i in items.size():
			items[i].prepare(placements[i].size, pair[2])
			items[i].position = placements[i].position
			items[i].size = placements[i].size
			items[i].place_handles(i < items.size() - 1)
	var heights := {"top": 0.0, "bottom": 0.0}
	for edge in bands:
		var rows: Array = bands[edge]
		if rows.is_empty(): continue
		var shown_heights: Array = band_heights[edge].duplicate()
		for index in rows.size():
			if rows[index].all(func(p): return p.dialog.folded): shown_heights[index] = MIN_BAND_HEIGHT
		var fitted := _fit_heights(edge, shown_heights, band_heights["bottom" if edge == "top" else "top"] if not bands["bottom" if edge == "top" else "top"].is_empty() else [])
		var rects := _row_rects(edge, fitted, left, right)
		for row_index in rows.size():
			var row: Array = rows[row_index]
			var placements := row_cells(row, band_weights[edge][row_index], rects[row_index])
			for index in row.size():
				var panel: Control = row[index]
				panel.prepare(placements[index].size, edge)
				panel.position = placements[index].position
				panel.size = Vector2(placements[index].size.x, MIN_BAND_HEIGHT) if panel.dialog.folded else placements[index].size
				panel.place_handles(index < row.size() - 1)
		heights[edge] = _rows_total(fitted) + gap()
	# The terminal tiling area's own inner gap supplies the content-side spacing;
	# reserve the sidebar and its outside margin, without doubling that gap.
	_reserve(Vector4(l.size.x + gap() if not left.is_empty() else 0, r.size.x + gap() if not right.is_empty() else 0, heights.top, heights.bottom))

## A column is as wide as its most magnified panel needs: the compact rail and
## the width below which it counts as collapsed both follow that panel.
func side_scale(side: String) -> float:
	var scale := 1.0
	for panel in column(side):
		if is_instance_valid(panel.dialog): scale = maxf(scale, panel.dialog.layout_scale())
	return scale

## A panel changed its magnification: whatever was sized to fit it follows.
func rescale(panel: Control, previous: float) -> void:
	var current: float = panel.dialog.layout_scale()
	if panel.side in ["left", "right"]:
		# A collapsed rail stays a rail, at the width the new size needs. A
		# width the user dragged to is theirs: only the content reflows in it.
		var others := 1.0
		for other in column(panel.side, panel):
			if is_instance_valid(other.dialog): others = maxf(others, other.dialog.layout_scale())
		if absf(widths[panel.side] - COLLAPSED_WIDTH * maxf(others, previous)) < 0.5:
			widths[panel.side] = COLLAPSED_WIDTH * maxf(others, current)
	reflow()
	save_layout()

func toggle_fold(side: String) -> void:
	if widths[side] < COMPACT_WIDTH * side_scale(side):
		widths[side] = expanded_widths[side]
	else:
		expanded_widths[side] = widths[side]
		widths[side] = COLLAPSED_WIDTH * side_scale(side)
	reflow()
	save_layout()

static func _valid_key(key: String) -> bool:
	return key in PANEL_KEYS or (key.begins_with("panel:") and key.length() > 6)

func load_layout() -> void:
	if state_path.is_empty() or not FileAccess.file_exists(state_path): return
	var data = JSON.parse_string(FileAccess.get_file_as_string(state_path))
	if not data is Dictionary or data.get("version") != 1 or not data.get("panels") is Dictionary: return
	if not data.get("band_rows") is Dictionary: return
	for side in ["top", "bottom"]:
		var rows = data.band_rows.get(side)
		if not rows is Array: return
		for height in rows:
			if not (height is float or height is int) or not is_finite(height) or height < MIN_BAND_HEIGHT or height > 10000: return
	for key in ["widths", "expanded"]:
		if not data.get(key) is Dictionary: return
		for side in ["left", "right"]:
			var width = data[key].get(side)
			if not (width is float or width is int) or not is_finite(width) or width < MIN_PANEL or width > 10000: return
	# A panel entry that is not in the current form is dropped on its own;
	# the widths and the other panels keep their places.
	var accepted: Dictionary = {}
	for key in data.panels:
		var entry = data.panels[key]
		if not _valid_key(str(key)) or not entry is Dictionary: continue
		if entry.get("side") not in ["", "left", "right", "top", "bottom"] or not entry.get("open") is bool: continue
		if not (entry.get("weight") is float or entry.get("weight") is int) or not is_finite(entry.weight) or entry.weight <= 0: continue
		if not (entry.get("order") is float or entry.get("order") is int) or entry.order < 0 or entry.order > 100: continue
		if not (entry.get("row") is float or entry.get("row") is int) or entry.row < 0 or entry.row > 8: continue
		if not entry.get("own_row") is bool or not entry.get("folded") is bool: continue
		if not (entry.get("scale") is float or entry.get("scale") is int) or not is_finite(entry.scale) or entry.scale < MIN_SCALE or entry.scale > MAX_SCALE: continue
		if not (entry.get("height") is float or entry.get("height") is int) or not is_finite(entry.height) or entry.height < MIN_BAND_HEIGHT or entry.height > 10000: continue
		accepted[key] = entry
	_saved = accepted
	band_rows = {"top": Array(data.band_rows.top), "bottom": Array(data.band_rows.bottom)}
	widths = data.widths
	expanded_widths = data.expanded

func save_layout(closed := "") -> void:
	if state_path.is_empty() or not _candidate.is_empty(): return
	for i in panels.size():
		var p: Control = panels[i]
		var key: String = p.dialog.persistence_key
		if key.is_empty(): continue
		# A band panel remembers whether the row was its own, and that row's height,
		# so reopening it after the band renumbered its rows gives the row back.
		var banded: bool = p.side in ["top", "bottom"]
		var stored: Array = band_rows.get(p.side, []) if banded else []
		var own_row: bool = banded and column(p.side).filter(func(q): return q.row == p.row).size() == 1
		var height: float = float(stored[p.row]) if banded and p.row < stored.size() else _preferred_row_height(p)
		_saved[key] = {"side": p.side, "row": p.row, "weight": p.weight, "order": i, "open": key != closed, "folded": p.dialog.folded, "own_row": own_row, "height": maxf(MIN_BAND_HEIGHT, height), "scale": p.dialog.layout_scale()}
	var data := {"version": 1, "widths": widths, "expanded": expanded_widths, "band_rows": band_rows, "panels": _saved}
	DirAccess.make_dir_recursive_absolute(state_path.get_base_dir())
	var file := FileAccess.open(state_path + ".tmp", FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(state_path + ".tmp", state_path)

func remember_closed(panel: Control) -> void:
	save_layout(panel.dialog.persistence_key)

func restore_panel(panel: Control) -> bool:
	var key: String = panel.dialog.persistence_key
	if not _saved.has(key): return false
	var entry: Dictionary = _saved[key]
	panel.dialog.folded = entry.folded and not panel.dialog.dock_only()
	if entry.side.is_empty(): return false
	if entry.side not in panel.dialog.dock_sides(): return false
	panel.side = entry.side
	panel.weight = entry.weight
	panel.row = 0
	if entry.side in ["top", "bottom"]:
		var rows := rows_of(entry.side, panel)
		var heights := heights_of(entry.side, rows)
		var index := clampi(int(entry.row), 0, rows.size())
		# A window that belongs at the band's window edge (Graffitty messages,
		# below the status line) returns there, whatever row an older layout saved.
		if entry.own_row and panel.dialog.default_dock_row() == "outer":
			index = rows.size() if entry.side == "bottom" else 0
		if entry.own_row or rows.is_empty():
			# Reinsert the panel's own row where it was, pushing later rows outward.
			for position in rows.size():
				for occupant in rows[position]: occupant.row = position + (1 if position >= index else 0)
			panel.row = index
			heights.insert(index, float(entry.height))
		else:
			panel.row = mini(index, rows.size() - 1)
			for position in rows.size():
				for occupant in rows[position]: occupant.row = position
		band_rows[entry.side] = heights
	panels.sort_custom(func(a, b): return _saved.get(a.dialog.persistence_key, {}).get("order", 100) < _saved.get(b.dialog.persistence_key, {}).get("order", 100))
	panel.dialog.attach_to_dock()
	reflow()
	save_layout()
	return true

static func restore_open(host: Node) -> void:
	if not is_instance_valid(host) or not host.is_inside_tree() or host.is_queued_for_deletion(): return
	var window := host.get_window()
	if (window.gui_embed_subwindows and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()) or window.has_meta(&"dock_restored"): return
	window.set_meta(&"dock_restored", true)
	var space := for_window(window)
	# Snapshot before either open() writes current geometry.
	var saved: Dictionary = space._saved.duplicate(true)
	var panel_window := load("res://scenes/mods/PanelWindow.gd")
	var config: Dictionary = preload("res://config/UserConfig.gd").resolved(OS.get_cmdline_user_args())
	for name in config.mod_order:
		var spec: Dictionary = config.mods[name]
		if spec.host not in ["panel", "bar"] or not spec.enabled: continue
		if saved.get(spec.persistence_key, {}).get("open", spec.open): panel_window.open(host, name)

func _reserve(insets: Vector4) -> void:
	var hosts := _window_hosts()
	for ref in _hosts:
		var old = ref.get_ref()
		if is_instance_valid(old) and old not in hosts and is_instance_valid(old.workspace_view): old.workspace_view.set_dock_insets(Vector4.ZERO)
	_hosts.clear()
	for host in hosts:
		_hosts.append(weakref(host))
		if is_instance_valid(host.workspace_view): host.workspace_view.set_dock_insets(insets)
	_reserved = insets
