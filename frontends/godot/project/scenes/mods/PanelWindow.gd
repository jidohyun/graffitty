extends "res://scenes/TranslucentPanelWindow.gd"
## A dockable window whose content is one JavaScript panel. The window owns
## docking, chrome and persistence; the panel owns everything drawn inside.
var mod_name := ""
var view: Control
var sides: Array[String] = ["left", "right"]
var load_error := ""
var _dock_only := false
## The whole panel draws this many times its natural size; saved with its placement.
var panel_scale := 1.0
const SCALE_STEP := 0.1


## Opens or raises the window for `name` in the host's window.
static func open(terminal_host: Node, name: String, extra_props := {}) -> Window:
	var spec := preload("res://scenes/mods/ModService.gd").manifest(name)
	if spec.is_empty() or not spec.enabled or spec.host not in ["panel", "bar"]:
		push_error("Mod %s is not a dockable panel" % name)
		return null
	var existing := find(terminal_host, name)
	if existing != null:
		existing.source = terminal_host
		existing.raise_panel()
		return existing
	var window: Window = load("res://scenes/mods/PanelWindow.gd").new()
	window.mod_name = name
	window.source = terminal_host
	window.set_meta(&"extra_props", extra_props)
	terminal_host.get_window().add_child(window)
	window.present()
	return window


static func find(terminal_host: Node, name: String) -> Window:
	if not terminal_host.is_inside_tree(): return null
	for child in terminal_host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == name and not child.is_queued_for_deletion():
			return child
	return null


static func toggle(terminal_host: Node, name: String) -> void:
	var existing := find(terminal_host, name)
	if existing != null: existing._close_panel()
	else: open(terminal_host, name)


func dock_sides() -> Array[String]:
	return sides


func dock_only() -> bool:
	return _dock_only


func layout_scale() -> float:
	return panel_scale


func _dock_space() -> Control:
	return preload("res://scenes/ListDockSpace.gd").for_window(get_parent().get_window())


## `direction` is +1 larger, -1 smaller, 0 back to the natural size.
func zoom_step(direction: int) -> void:
	set_panel_scale(1.0 if direction == 0 else panel_scale + SCALE_STEP * direction)


func set_panel_scale(value: float, remember := true) -> void:
	var space := _dock_space()
	value = snappedf(clampf(value, space.MIN_SCALE, space.MAX_SCALE), 0.01)
	if is_equal_approx(value, panel_scale): return
	var previous := panel_scale
	panel_scale = value
	if view != null and view.has_method("set_zoom"): view.set_zoom(panel_scale)
	if is_instance_valid(_desktop): _desktop.apply_scale()
	_publish_props()
	if not remember: return
	if is_instance_valid(_desktop) and not _desktop.side.is_empty():
		space.rescale(_desktop, previous)
		return
	# A floating panel has no dock row to resize; only its saved entry changes.
	if space._saved.has(persistence_key): space._saved[persistence_key].scale = panel_scale
	geometry_changed()
	space.save_layout()


## The panel under the pointer in the host's window, or null.
static func under_pointer(terminal_host: Node) -> Window:
	if not terminal_host.is_inside_tree(): return null
	var owner_window := terminal_host.get_window()
	var pointer := owner_window.get_mouse_position()
	for child in owner_window.get_children():
		if not (child is Window and child.is_in_group(&"panel_window")) or child.is_queued_for_deletion(): continue
		var desktop: Control = child._desktop
		if is_instance_valid(desktop) and not desktop.side.is_empty():
			if desktop.is_visible_in_tree() and desktop.get_global_rect().has_point(pointer): return child
		elif child.visible and not child.force_native and Rect2(Vector2(child.position), Vector2(child.size)).has_point(pointer):
			return child
	return null


## A floating panel has the keyboard itself; the same font-size keys magnify it.
func _input(event: InputEvent) -> void:
	if _zoom_key(event): set_input_as_handled()
	else: super(event)


func _zoom_key(event: InputEvent) -> bool:
	if not (event is InputEventKey and event.pressed) or not is_instance_valid(source) or source.get("bindings") == null: return false
	if is_instance_valid(_desktop) and not _desktop.side.is_empty(): return false
	var action: String = source.bindings.direct_action(event.get_keycode_with_modifiers())
	var steps: Dictionary = preload("res://scenes/HostActions.gd").FONT_SIZE
	if not steps.has(action): return false
	zoom_step(steps[action])
	return true


func default_dock_side() -> String:
	# A saved floating placement is deliberate; only new panels use defaults.
	if not dock_only() and is_instance_valid(_desktop) and _desktop.space._saved.has(persistence_key): return ""
	var spec := preload("res://scenes/mods/ModService.gd").manifest(mod_name)
	var place := str(spec.get("place", "none"))
	return place if place in sides else ""


func _ready() -> void:
	var manifest: Dictionary = preload("res://scenes/mods/ModService.gd").manifest(mod_name)
	_dock_only = manifest.get("host") == "bar"
	var place := str(manifest.get("place", "none"))
	var allowed = manifest.get("sides", ["top", "bottom"] if place in ["top", "bottom"] else ["left", "right"])
	sides.assign(allowed if allowed is Array else ["left", "right"])
	title = tr(str(manifest.get("title", mod_name.capitalize())))
	persistence_key = str(manifest.get("persistence_key", "panel:" + mod_name))
	var blur = manifest.get("background_blur", true)
	if blur is bool: background_blur = blur
	else: push_error("Mod %s: background_blur must be a boolean" % mod_name)
	var radius = manifest.get("background_blur_radius", 12.0)
	if valid_blur_radius(radius): background_blur_radius = float(radius)
	else: push_error("Mod %s: background_blur_radius must be a finite number from 0 to 64" % mod_name)
	var opacity = manifest.get("background_opacity", 1.0)
	if opacity is float or opacity is int: background_opacity = clampf(float(opacity), 0.0, 1.0)
	else: push_error("Mod %s: background_opacity must be a number from 0 to 1" % mod_name)
	# `size` is the extent along the docked axis; a mod placed nowhere keeps the
	# default floating window.
	if manifest.has("size") and place != "none":
		var extent := float(manifest.size)
		set_meta(&"preferred_size", Vector2i(420, int(extent)) if place in ["top", "bottom"] else Vector2i(int(extent), 560))
	add_to_group(&"panel_window")
	super()
	_reload()
	set_panel_scale(float(_dock_space()._saved.get(persistence_key, {}).get("scale", 1.0)), false)
	_publish_props()
	var service: Node = _service()
	if service != null and is_instance_valid(source): service.publish_window(source)


func _service() -> Node:
	# The host's application owns the service; the autoload path is the fallback.
	if is_instance_valid(source) and source.get("application") != null and source.application.get("mods") != null:
		return source.application.mods
	var app := get_node_or_null("/root/TerminalApplication")
	return app.mods if app != null and "mods" in app else null


func _create_content() -> Control:
	view = ClassDB.instantiate("ModView") if ClassDB.class_exists("ModView") else Control.new()
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.resized.connect(_view_resized)
	return view


func _props() -> Dictionary:
	var props := {"window": source.get_instance_id() if is_instance_valid(source) else 0, "compact": compact, "row": compact_row,
		"docked": is_instance_valid(_desktop) and not _desktop.side.is_empty(), "side": _desktop.side if is_instance_valid(_desktop) else "",
		# The mod's own width in logical pixels, for layouts that change with room.
		"width": roundi(view.size.x / panel_scale) if view != null else 0}
	props.merge(get_meta(&"extra_props", {}))
	return preload("res://scenes/mods/ModService.gd").mod_props(mod_name, props)


func _reload() -> void:
	var service: Node = _service()
	if service == null or not view.has_method("load_entry"):
		load_error = "panels are unavailable"
		return
	load_error = service.load_into(view, mod_name, _props())
	if not load_error.is_empty(): push_error("Panel %s: %s" % [mod_name, load_error])
	else: add_to_group(&"panel_window_%d" % int(view.copy_id()))


func _publish_props() -> void:
	if view != null and view.has_method("set_props") and view.copy_id() >= 0:
		view.set_props(JSON.stringify(_props()))
		_published_width = roundi(view.size.x)


var _published_width := -1
## Width changes reach the mod as props; whole pixels only, so drags stay cheap.
func _view_resized() -> void:
	if view != null and roundi(view.size.x) != _published_width: _publish_props()


func _compact_changed() -> void:
	_publish_props()


func attach_to_dock() -> void:
	super()
	_publish_props()


func float_native(screen_position := Vector2.INF) -> void:
	super(screen_position)
	_publish_props()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		var manifest: Dictionary = preload("res://scenes/mods/ModService.gd").manifest(mod_name)
		title = tr(str(manifest.get("title", mod_name.capitalize())))


## The panel's text runs, for tests and diagnostics.
func texts() -> PackedStringArray:
	if view == null or not view.has_method("render_now"): return PackedStringArray()
	view.render_now()
	return view.texts()
