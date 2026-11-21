extends Control
signal navigation_changed
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
## Workspace chrome and windows. The tab bar lives in window space; dockable
## tools are owned separately by the application Window.
##
## Every pane lives in `canvas`, one flat image the world paints on its
## terminal sheet, so a single camera moves the world and all windows
## together: typing zoom, lean, depth of field, flights.
##
## Pointer input is un-projected through that camera into the canvas.
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
const Layout := preload('res://scenes/WorkspaceLayout.gd')
const TypingPaneZoom := preload("res://scenes/TypingPaneZoom.gd")
const BAR_HEIGHT := 36.0
const HEADER_HEIGHT := 30.0
# Keep title-bar actions until roughly half size; show the pane strip sooner.
const COMPACT_HEADER_THRESHOLD := 15.0
const STATUS_STRIP_THRESHOLD := 24.0
const Mods := preload("res://scenes/mods/ModService.gd")
## Header drag handle that stays inside the frame so a window can be grabbed again.
const GRAB_EXTENT := 80.0
## Holding a dragged window's pointer in this band at the view's edge, for
## EDGE_PAN_DELAY seconds, pans the view.
const EDGE_PAN_BAND := 24.0
const EDGE_PAN_DELAY := .25
## Ease from rest to the cap after the dwell, in screen pixels per second.
const EDGE_PAN_RAMP := .8
const EDGE_PAN_MAX_SPEED := 800.0
## Canvas texels per window pixel, as the single-terminal sheet had: typing
## zoom magnifies the canvas without softening text.
const SUPERSAMPLING := 2.0
const TEXTURE_MAX_SIDE := 8192.0
## A wall far wider than the window must not cost a canvas far larger than it.
const TEXTURE_MAX_PIXELS := 20_000_000.0
var host: Node
var tab_bar: Control
## Clip fixed workspace overlays below the tabs without changing their
## coordinates.
##
## The inner root cancels the clip's offset, so projection and drag math stay
## in full-window coordinates while both drawing and pointer picking respect
## the edge.
var foreground_clip := Control.new()
var foreground_root := Control.new()
## Windows, in sheet layout pixels. Its texture is the world sheet's texture.
var canvas := SubViewport.new()
var canvas_root := Control.new()
var chromium_links := preload("res://scenes/WorkspaceChromiumLinks.gd").new()
var agent_links := preload("res://scenes/AgentGraphOverlay.gd").new()
## Catches pointer input under the fixed chrome and forwards it into the canvas.
var pointer := preload("res://scenes/WorkspacePointer.gd").new()
## Desktop position of the last pointer event forwarded into the canvas.
var pointer_screen := Vector2.ZERO
var panes: Dictionary = { }
## Inherit PaneHeader.tscn to style pane chrome without replacing pane behavior.
@export var pane_header_scene: PackedScene = preload("res://scenes/PaneHeader.tscn")
## What each pane's strip shows (ModService.pane_status), published to its mod.
var pane_status: Dictionary = { }
var pane_titles: Dictionary[String, Label] = { }
var status_strips: Dictionary = { }
var _status_layout_snapshot: Array = []
var _status_placements: Dictionary = { }
var _status_motion: Dictionary = { }
var status_layout_updates := 0
var _status_sources: Dictionary = { }
var _status_graph: Node
## Pane whose title row is under the pointer; only it shows title actions.
var _hovered_header := ""
var pane_rects: Dictionary[String, Rect2] = { }
## Logical sheet area covered by the raster, independent of pane/PTY sizes.
var raster_region := Rect2()
var navigation_render_until := 0
var navigation_render_frame := -10
var _navigation_render_timer := Timer.new()
var drop_hint := Panel.new()
var hint_text := Label.new()
var _refreshing := false
var _held := 0
var _pointer_in_canvas := false
var _navigation_drag := false
var mobile_pointer: Control
var _navigation_press: InputEventMouseButton
var _navigation_delta := Vector2.ZERO
var _last_gesture: Array = []
## Generic Godot gestures omit native phase/centroid data. Remember their
## starting anchor until inactivity or ordinary pointer input ends the pinch.
var _pinch_anchor := Vector2.INF
var _pinch_last_msec := 0
@export var pinch_pan_speed := 3.0
const PINCH_IDLE_MSEC := 350
var overview := false
var navigation_center := Vector2.ZERO
var navigation_zoom := 1.0
## How far Android's keyboard and compact chrome moved this view's centre on
## screen. Saved navigation leaves it out, as if the keyboard were closed.
var inset_shift := Vector2.ZERO
var _remote_move_tween: Tween
var _remote_move_offsets := {}
var _remote_move_weight := 0.0
var _remote_move_tab := -1
var _inspect_tween: Tween
var _fit_return: Dictionary = { }
var _main_magnet_held := false
var _main_magnet_raw_center := Vector2.ZERO
var _main_magnet_raw_zoom := 1.0
var _main_magnet_input_ms := 0
var moving := ""
var toolbar := HBoxContainer.new()
var tile_button: Button
var split_right_button: Button
var split_down_button: Button
var overview_button: Button
var main_button: Button
var boundary := Panel.new()
var layout_preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
var preview_plan: Dictionary = { }
var tile_resize: Dictionary = { }
var pane_physics := preload("res://scenes/WorkspacePhysics.gd").new()
var physics_tab := -1
var physics_typing := false
var _typing_tab := -1
var _typing_timer := Timer.new()
var _pane_zoom := TypingPaneZoom.new()
var _pane_zoom_tab := -1
var _projection_world: Node
var _presentation_pending := false
var _headers_dirty := false
var _last_presentation_frame := -1
var _raster_dirty := false
var _links_dirty := false


func bind_host(value: Node) -> void:
	host = value


var _initialized := false


func _ready() -> void:
	set_process(false)
	_typing_timer.one_shot = true
	_typing_timer.wait_time = 0.8
	_typing_timer.timeout.connect(_typing_finished)
	add_child(_typing_timer)
	_navigation_render_timer.one_shot = true
	_navigation_render_timer.wait_time = 0.16
	_navigation_render_timer.timeout.connect(_finish_navigation_render)
	add_child(_navigation_render_timer)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	foreground_clip.name = "ForegroundClip"
	foreground_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foreground_clip.clip_contents = true
	add_child(foreground_clip)
	foreground_root.name = "Foreground"
	foreground_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foreground_clip.add_child(foreground_root)
	# First visual child, so the tab bar keeps its own input.
	pointer.mouse_filter = Control.MOUSE_FILTER_STOP
	pointer.focus_mode = Control.FOCUS_NONE
	foreground_root.add_child(pointer)
	pointer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pointer.gui_input.connect(_forward_pointer)
	pointer.mouse_entered.connect(_pointer_entered)
	pointer.mouse_exited.connect(_pointer_left)
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		mobile_pointer = preload("res://scenes/input/MobilePointer.gd").new()
		mobile_pointer.view = self
		add_child(mobile_pointer)
	# Linear premultiplied, like the terminal textures the sheet shader expects.
	canvas.transparent_bg = true
	canvas.use_hdr_2d = true
	canvas.disable_3d = true
	# Redrawn only when something on it changed: Chromium page frames in a
	# world with a video layer reach the screen without it.
	RenderUpdates.configure(canvas, true)
	canvas.handle_input_locally = true
	# Menus and tooltips stay on the sheet with the window they belong to.
	canvas.gui_embed_subwindows = true
	# Godot draws deeper viewports first, then siblings in creation order.
	#
	# Inside the world's viewport, ahead of its 3D passes, and holding the
	# terminals' viewports, every frame renders terminals, then this canvas, then
	# the world that shows it.
	#
	# Anywhere shallower, the sheet lags output by two frames.
	host.world_viewport.add_child(canvas)
	canvas_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(canvas_root)
	# Keep routing in screen coordinates, but render ownership wires below panes.
	foreground_root.add_child(chromium_links)
	chromium_links.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	chromium_links.mount_wire_layer(canvas_root, canvas_point_at)
	foreground_root.add_child(agent_links)
	agent_links.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Blender node_draw_nodetree draws established links before foreground nodes.
	# Share the terminal canvas so pane contents naturally occlude the links.
	agent_links.mount_wire_layer(canvas_root, canvas_point_at)
	if tab_bar == null:
		tab_bar = host.ui.create_tab_strip()
		add_child(tab_bar)
	tab_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	tab_bar.offset_bottom = 34
	tab_bar.z_index = 10
	tab_bar.item_rect_changed.connect(host._sync_world_chrome_clip)
	tab_bar.visibility_changed.connect(host._sync_world_chrome_clip)
	tab_bar.item_rect_changed.connect(host._resize_menu_content, CONNECT_DEFERRED)
	tab_bar.visibility_changed.connect(host._resize_menu_content, CONNECT_DEFERRED)
	tab_bar.item_rect_changed.connect(_sync_foreground_clip)
	tab_bar.visibility_changed.connect(_sync_foreground_clip)
	drop_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drop_hint.z_index = 30
	var hint_style := StyleBoxFlat.new()
	hint_style.set_content_margin_all(16)
	hint_style.set_corner_radius_all(8)
	hint_style.bg_color = Color(0.25, 0.49, 0.8, 0.25)
	hint_style.border_color = Color('88baff')
	hint_style.set_border_width_all(2)
	drop_hint.add_theme_stylebox_override('panel', hint_style)
	hint_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	drop_hint.add_child(hint_text)
	hint_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas_root.add_child(drop_hint)
	drop_hint.hide()
	# This border lives on the sheet, so its dimensions track the OS window.
	boundary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boundary.hide()
	var border := StyleBoxFlat.new()
	border.bg_color = Color(0, 0, 0, 0)
	border.border_color = Color("8ecaff")
	border.set_border_width_all(4)
	boundary.add_theme_stylebox_override("panel", border)
	canvas_root.add_child(boundary)
	canvas_root.move_child(boundary, 0)
	toolbar.position = Vector2(8, BAR_HEIGHT + 4)
	toolbar.z_index = 15
	foreground_root.add_child(toolbar)
	for button in [tile_button, split_right_button, split_down_button, overview_button, main_button]:
		if button == null:
			continue
		button.focus_mode = Control.FOCUS_NONE
		if button.get_parent() == null:
			toolbar.add_child(button)
	if tile_button != null:
		tile_button.toggle_mode = true
		tile_button.text = "Tile"
		tile_button.tooltip_text = "Tile windows inside the main area; stashed windows stay free"
		tile_button.pressed.connect(toggle_tiling)
	if split_right_button != null:
		split_right_button.icon = split_icon(false)
		split_right_button.tooltip_text = "New pane right (prefix, then backslash)"
		split_right_button.pressed.connect(split_window.bind("h"))
	if split_down_button != null:
		split_down_button.icon = split_icon(true)
		split_down_button.tooltip_text = "New pane below (prefix, then -)"
		split_down_button.pressed.connect(split_window.bind("v"))
	if overview_button != null:
		overview_button.text = "Overview"
		overview_button.pressed.connect(show_overview)
	if main_button != null:
		main_button.text = "Fit to main area"
		main_button.pressed.connect(fit_to_main_area)
	toolbar.visible = toolbar.get_child_count() > 0
	canvas_root.add_child(layout_preview)
	layout_preview.hide()
	get_window().focus_exited.connect(cancel_tile_resize)
	get_window().focus_exited.connect(_cancel_navigation_drag)
	resized.connect(cancel_tile_resize)
	resized.connect(_sync_foreground_clip)
	resized.connect(func(): _refresh_after_resize.call_deferred())
	_sync_foreground_clip()
	_initialized = true


func _foreground_rect() -> Rect2:
	var top := 0.0
	if is_instance_valid(host):
		top = clampf(host.workspace_chrome_bottom() - global_position.y, 0.0, size.y)
	return Rect2(0, top, maxf(0, size.x), maxf(0, size.y - top))


func _sync_foreground_clip() -> void:
	var area := _foreground_rect()
	foreground_clip.position = area.position
	foreground_clip.size = area.size
	foreground_root.position = -area.position
	foreground_root.size = size
	toolbar.position.y = area.position.y + 4.0
	_links_dirty = true
	_invalidate_headers()


## One vector icon per action; no font-specific glyph dependency.
func split_icon(down: bool) -> Texture2D:
	var divider := '<path d="M3 12h18"/>' if down else '<path d="M12 3v18"/>'
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/>' + divider + '</g></svg>'
	return DPITexture.create_from_string(svg, 28.0 / 24.0)


## Context-menu variant: the split icon plus an arrow inside the half where the
## new pane appears ("left", "right", "up", "down").
func split_direction_icon(direction: String) -> Texture2D:
	var arrows := {
		"left": "M10.5 12H5.5M7.5 10L5.5 12L7.5 14",
		"right": "M13.5 12H18.5M16.5 10L18.5 12L16.5 14",
		"up": "M12 10.5V5.5M10 7.5L12 5.5L14 7.5",
		"down": "M12 13.5V18.5M10 16.5L12 18.5L14 16.5",
	}
	assert(arrows.has(direction), "Unknown split direction: " + direction)
	var down := direction == "up" or direction == "down"
	var divider := '<path d="M3 12h18"/>' if down else '<path d="M12 3v18"/>'
	var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/>' + divider + '<path stroke-width="1.75" d="' + arrows[direction] + '"/></g></svg>'
	return DPITexture.create_from_string(svg, 28.0 / 24.0)


func dividers_at(point: Vector2, touch := false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not moving.is_empty() or not host.application.drag.is_empty():
		return result
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var tree: Dictionary = group.get("tree", { })
	if not tree.get("tiling", false):
		return result
	var over := window_at(point)
	if (
		not over.is_empty()
		and (
			Layout.find(tree, over).get("stashed", false)
			or Layout.find(tree, over).get("graph_floating", false)
		)
	):
		return result
	var nearest := { }
	var distances := { }
	for divider in Layout.tile_dividers(
		tree.get("tiles", { }),
		Layout.tiling_area(tree, content_rect()),
		[],
		host.tiling_config.gap,
	):
		# Mouse borders retain their existing grip. Finger targets stay at
		# least 44 screen pixels wide through zoom and camera tilt.
		var padding := Vector2(12, 12)
		if touch:
			var screen := window_point(point)
			var pixels := Vector2(
				screen.distance_to(window_point(point + Vector2.RIGHT)),
				screen.distance_to(window_point(point + Vector2.DOWN)),
			)
			padding = Vector2(22, 22) / pixels.max(Vector2(.001, .001))
			if divider.axis == "h": padding.x = maxf(0, padding.x - divider.rect.size.x * .5)
			else: padding.y = maxf(0, padding.y - divider.rect.size.y * .5)
		if not divider.rect.grow_individual(padding.x, padding.y, padding.x, padding.y).has_point(point):
			continue
		var distance := (
			absf(point.x - divider.rect.get_center().x)
			if divider.axis == "h"
			else absf(point.y - divider.rect.get_center().y)
		)
		if distance < distances.get(divider.axis, INF):
			distances[divider.axis] = distance
			nearest[divider.axis] = divider
	for axis in ["h", "v"]:
		if nearest.has(axis):
			result.append(nearest[axis])
	return result


func divider_cursor(dividers: Array[Dictionary], point: Vector2) -> int:
	if dividers.size() == 2:
		var key := window_at(point)
		if pane_rects.has(key):
			var delta: Vector2 = point - pane_rects[key].get_center()
			return Control.CURSOR_FDIAGSIZE if delta.x * delta.y >= 0 else Control.CURSOR_BDIAGSIZE
		return Control.CURSOR_FDIAGSIZE
	return Control.CURSOR_HSIZE if dividers[0].axis == "h" else Control.CURSOR_VSIZE


func cancel_tile_resize() -> void:
	if tile_resize.is_empty():
		return
	var group: Dictionary = host.workspace_layout.tab(tile_resize.tab)
	if not group.is_empty():
		group.tree["tiles"] = tile_resize.before
	tile_resize = { }
	agent_links.tools.before = {}
	_held = 0
	pointer.mouse_default_cursor_shape = Control.CURSOR_ARROW
	refresh()
	if not group.is_empty():
		# A metadata-triggered commit may have reached the owner mid-drag.
		# Cancellation must publish the restored weights as the newest edit.
		host.session_backend.resize_tiles(host)
		host.ui_changed.emit()


func _start_tile_resize(point: Vector2, touch := false) -> bool:
	var dividers := dividers_at(point, touch)
	if dividers.is_empty():
		return false
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	agent_links.tools.sync()
	agent_links.tools.begin_edit()
	tile_resize = {
		"tab": group.id,
		"before": group.tree.tiles.duplicate(true),
		"dividers": dividers,
		"start": point,
	}
	pointer.mouse_default_cursor_shape = divider_cursor(dividers, point)
	return true


func _update_tile_resize(point: Vector2) -> void:
	var group: Dictionary = host.workspace_layout.tab(tile_resize.tab)
	if group.is_empty() or host.workspace_layout.active != tile_resize.tab:
		cancel_tile_resize()
		return
	var delta: Vector2 = point - tile_resize.start
	var tiles: Dictionary = tile_resize.before.duplicate(true)
	for divider in tile_resize.dividers:
		Layout.resize_tiles(tiles, divider, delta.x if divider.axis == "h" else delta.y)
	group.tree["tiles"] = tiles
	refresh()


func _refresh_after_resize() -> void:
	if not is_inside_tree(): return
	# Container sizes and chrome settle after the resize signal. Refit using
	# those final dimensions, even while an unfocused world's animation sleeps.
	refresh()
	if host == null or not is_instance_valid(host.world): return
	var world: Node = host.world
	if world.navigation_camera != null:
		world.navigation_camera.reset(canvas_size())
	world._fit_uv_basis()
	world._apply_camera_fx()


## The canvas is this view as the resting camera frames it, in layout pixels:
## window rectangles are canvas rectangles, in every world.
func canvas_size() -> Vector2:
	# Round up, but not for float noise.
	return (size - Vector2(.01, .01)).ceil()


func canvas_scale() -> float:
	return maxf(
		float(canvas.size.x) / maxf(raster_region.size.x, 1.0),
		float(canvas.size.y) / maxf(raster_region.size.y, 1.0),
	)


func sync_canvas() -> void:
	var layout := Vector2i(canvas_size())
	if layout.x < 1 or layout.y < 1:
		return
	if not raster_region.has_area():
		raster_region = Rect2(Vector2.ZERO, Vector2(layout))
	var physical := get_viewport().get_final_transform().get_scale().x
	# Respect device pixel density on mobile: one logical pixel may cover several
	# screen pixels. Keep desktop's extra supersampling out of phone render targets.
	var mobile := OS.has_feature("android") or OS.has_feature("ios")
	var pixel_budget := 4_000_000.0 if mobile else TEXTURE_MAX_PIXELS
	var zoom := 1.0
	var world: Node = host.world
	if world != null and (is_overview() or world.fx_cam_zoom * world.gesture_zoom > 1.15) and world.fly_dur <= 0.0 and world.tab_fx_t < 0.0:
		zoom = maxf(world._navigation_camera_zoom() if is_overview() else world.fx_cam_zoom * world.gesture_zoom, 0.05)
	# The crop includes off-screen padding and perspective bounds. A fixed-size
	# target spends pixels on that padding and loses text density while zooming.
	# Preserve screen density, in half-step increments to avoid per-frame reallocs.
	var density := ceilf((1.0 if mobile else SUPERSAMPLING) * maxf(physical, 1.0) * zoom * 2.0) / 2.0
	var scale := minf(
		density,
		TEXTURE_MAX_SIDE / maxf(raster_region.size.x, raster_region.size.y),
	)
	scale = minf(scale, sqrt(pixel_budget / maxf(raster_region.get_area(), 1.0)))
	var raster := Vector2i((raster_region.size * scale).floor()).max(Vector2i.ONE)
	canvas.size_2d_override = layout
	canvas.size_2d_override_stretch = true
	canvas.oversampling = true
	if canvas.size != raster and not holding_navigation_render_targets():
		canvas.size = raster
	canvas_root.size = Vector2(layout)


func update_raster_region() -> void:
	var full := Rect2(Vector2.ZERO, canvas_size())
	var region := full
	var world: Node = host.world
	if (
		world != null
		and world.fly_dur <= 0.0 and world.tab_fx_t < 0.0
	):
		# The server's retained sheet can exceed this client's logical canvas,
		# including at normal zoom after a tab/world switch. Always measure the
		# visible sheet; cropping to canvas_size() would discard visible panes.
		var bounds := Rect2()
		var first := true
		# Sample the edges as well as corners: the sheet can be bent.
		for x in 5:
			for y in 5:
				var point: Vector2 = world.sheet_point_at(Vector2(x, y) / 4.0)
				if not point.is_finite():
					continue
				bounds = Rect2(point, Vector2.ZERO) if first else bounds.expand(point)
				first = false
		if not first:
			bounds = bounds.grow(48.0)
			if bounds.has_area():
				var start := (bounds.position / 32.0).floor() * 32.0
				var end := (bounds.end / 32.0).ceil() * 32.0
				region = Rect2(start, end - start)
	if not region.has_area():
		return
	var changed := not region.is_equal_approx(raster_region)
	raster_region = region
	var previous_size := canvas.size
	sync_canvas()
	changed = changed or canvas.size != previous_size
	var scale := full.size / region.size
	var mapping := Transform2D(Vector2(scale.x, 0), Vector2(0, scale.y), -region.position * scale)
	if not canvas.canvas_transform.is_equal_approx(mapping):
		canvas.canvas_transform = mapping
	if world != null and world.fx_mat != null:
		world.set_workspace_render_region(
			Rect2(region.position / full.size, region.size / full.size)
		)
	boundary.visible = main_boundary_visible()
	# Also supports custom worlds that publish their camera through this method.
	_links_dirty = true
	_invalidate_headers()
	if changed:
		for pane in panes.values():
			if pane.visible:
				pane._resize_terminal_preview()


func refresh() -> void:
	# Native window chrome can synchronously request layout while _ready builds
	# the tab strip. Wait until all workspace controls have been attached.
	if not _initialized:
		return
	if not overview and host != null and host.session_backend != null:
		var target := main_frame()
		navigation_center = target.center
		navigation_zoom = target.zoom
	if (
		_refreshing or not is_node_ready() or not is_inside_tree() or get_viewport() == null or not host.presentation_active
		or not canvas.is_inside_tree() or host.layout_transaction or size.x < 2 or size.y < 72
	):
		return
	if not tile_resize.is_empty() and host.workspace_layout.active != tile_resize.tab:
		cancel_tile_resize()
	_refreshing = true
	_bind_projection_world()
	if physics_typing and _typing_tab != host.workspace_layout.active:
		_typing_timer.stop()
		_typing_finished()
	sync_canvas()
	adopt_terminal_viewports()
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.has("tree") and not group.tree.has("tiling_gap"):
		group.tree["tiling_gap"] = host.tiling_config.gap
	var shown: Array[String] = Layout.keys(group.get('tree', { }), true)
	for key in panes.keys():
		if host.workspace_layout.containing(key) < 0:
			# The owner may have queued its viewport first. Drop this consumer
			# before deferred deletion makes its ViewportTexture invalid.
			panes[key].texture.texture = null
			panes[key].queue_free()
			panes.erase(key)
		else:
			panes[key].visible = key in shown
			# Hovering another tab hides a dragged pane. Without an OS pointer to
			# poll (Android), only its own input can still move or release it.
			var gesture: bool = panes[key]._pressed or panes[key]._resizing
			panes[key].process_mode = Node.PROCESS_MODE_INHERIT if key in shown or gesture else Node.PROCESS_MODE_DISABLED
	for key in shown:
		if not panes.has(key):
			var pane := preload('res://scenes/WorkspacePane.gd').new(pane_header_scene)
			pane.host = host
			pane.key = key
			panes[key] = pane
			canvas_root.add_child(pane)
			pane.header_changed.connect(_invalidate_headers)
			pane.item_rect_changed.connect(_invalidate_headers)
			pane.visibility_changed.connect(_invalidate_headers)
			pane.handle.item_rect_changed.connect(_invalidate_headers)
			pane.body.item_rect_changed.connect(_invalidate_headers)
		panes[key].show()
		var id := int(key.substr(1))
		if host.is_terminal_pane(key) and not host.sessions.has(id) and host.world != null:
			host.session_for(id, host.world)
		panes[key].refresh()
	pane_rects.clear()
	Layout.arrange(
		group.get('tree', { }),
		content_rect(),
		pane_rects,
		group.get("focused", ""),
		moving,
	)
	var tiled_area := Layout.tiling_area(group.get('tree', { }), content_rect())
	for key in pane_rects:
		# Render the canonical position, including newly created neighbors above
		# Main View. Clamping here overlaps them with their source and prevents
		# focus navigation from seeing that they need to be revealed.
		#
		# Pointer moves still enforce reachability in set_window_rect().
		panes[key].position = pane_rects[key].position
		panes[key].size = pane_rects[key].size
		panes[key].refresh_background(group.get('tree', { }), tiled_area)
		_apply_pane_zoom(key)
		panes[key]._resize_terminal_preview()
	_sync_chromium_links()
	# One full-frame world behind every floating window. Never reset its
	# anchors on refresh: that briefly shrank the PTY on every UI click.
	host.world_container.visible = host.world != null
	RenderUpdates.set_enabled(host.world_viewport, host.presentation_active and host.world_container.visible)
	for id in host.sessions:
		var visible_terminal: bool = ('%%%d' % id) in shown
		var vp: SubViewport = host.sessions[id].vp
		# Visible panes set their own raster visibility after crop calculation.
		if not visible_terminal: preload("res://scenes/TerminalViewportUpdates.gd").set_visible(vp, false)
		preload("res://scenes/TerminalViewportInput.gd").set_disabled(vp,
			not visible_terminal or not host.is_terminal_pane(host.pane_focus)
			or id != host.active_session_id
		)
	for id in host.chromiums:
		host.chromiums[id].selected = ('%%%d' % id) in shown
	if tile_button != null:
		tile_button.set_pressed_no_signal(group.get("tree", { }).get("tiling", false))
	var focused := Layout.find(group.get("tree", { }), host.pane_focus)
	var can_split: bool = (not focused.is_empty() and focused.get("shown", true))
	if split_right_button != null:
		split_right_button.disabled = not can_split
	if split_down_button != null:
		split_down_button.disabled = not can_split
	boundary.position = content_rect().position
	boundary.size = content_rect().size
	# Layout changes must update the canvas mapping even when the world's
	# animation loop sleeps in an inactive window. Otherwise the old X/Y
	# scale squeezes the entire workspace into the newly sized viewport.
	_sync_status_sources()
	update_raster_region()
	_update_compact_headers()
	_update_monitor()
	_refreshing = false
	host.session_backend.sync_window_area(host)
	wake_pane_physics()
	queue_redraw()


func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("WorkspaceView._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_pinch_anchor = Vector2.INF
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and is_instance_valid(host):
		_update_monitor()
		for key in status_strips: _refresh_status(key)

## Publishes the focused pane's samples and identity to the mods (the
## Pane Status panel and status line read them). Nothing renders unless they changed.
func _update_monitor() -> void:
	if not is_inside_tree() or not is_visible_in_tree(): return
	if host.application != null and host.application.mods != null: host.application.mods.publish_window(host)


## Unknown or stale samples must never look like a measured zero.
static func overview_resource_text(data: Dictionary, key: String, position := 0) -> String:
	var r: Dictionary = Mods.pane_resources(data, key, position)
	return "%s · CPU %s · RAM %s" % [r.label, r.cpu, r.memory]


func _compact_resources(key: String, position := -1) -> Dictionary:
	if position < 0:
		var tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
		position = Layout.numbered_keys(tab.get("tree", {}), tab.get("focused", "")).find(key) + 1
	return Mods.pane_status(host, key, position)


func _sync_status_sources() -> void:
	var graph: Node = host.agent_api.graph if host.agent_api != null else null
	if _status_graph != graph:
		if is_instance_valid(_status_graph):
			_status_graph.changed.disconnect(_agent_status_changed)
		_status_graph = graph
		if is_instance_valid(graph): graph.changed.connect(_agent_status_changed)
	for key in _status_sources.keys():
		var source: Node = host.resource_monitor_for(int(key.substr(1))) if panes.has(key) else null
		if not is_instance_valid(_status_sources[key]) or _status_sources[key] != source:
			if is_instance_valid(_status_sources[key]):
				_status_sources[key].snapshot_changed.disconnect(_resource_status_changed.bind(key))
			_status_sources.erase(key)
	var positions := {}
	for key in panes:
		if not positions.has(key):
			var tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
			var ordered := Layout.numbered_keys(tab.get("tree", {}), tab.get("focused", ""))
			for index in ordered.size(): positions[ordered[index]] = index + 1
		if not _status_sources.has(key):
			var source: Node = host.resource_monitor_for(int(key.substr(1)))
			if source != null:
				_status_sources[key] = source
				source.snapshot_changed.connect(_resource_status_changed.bind(key))
		# Layout changes can renumber a pane without a new resource sample.
		_refresh_status(key, positions.get(key, 0))


func _resource_status_changed(_data: Dictionary, key: String) -> void:
	_refresh_status(key)
	if host.pane_focus == key: _update_monitor()
	var mods: Node = _mods()
	if mods != null: mods.queue_pane_resources()
	_invalidate_headers()


func _agent_status_changed() -> void:
	_links_dirty = true # Explicit edges can hide/reveal an ownership wire.
	for key in status_strips:
		if host.is_terminal_pane(key): _refresh_status(key)
	for key in panes: _refresh_header_agent(key)
	_update_monitor()
	_invalidate_headers()


func _refresh_status(key: String, position := -1) -> void:
	pane_status[key] = _compact_resources(key, position)
	var mods: Node = _mods()
	if mods != null: mods.publish_pane(host, key, pane_status[key])


func _mods() -> Node:
	return host.application.mods if host != null and host.get("application") != null and host.application.get("mods") != null else null


## Without a status strip, the title row keeps a running/awaiting agent visible.
func _refresh_header_agent(key: String) -> void:
	var pane: Control = panes.get(key)
	if not is_instance_valid(pane) or not pane.is_node_ready(): return
	var status := ""
	if host.is_terminal_pane(key) and host.agent_api != null:
		status = str(host.agent_api.graph.public_node(key).get("status", ""))
	pane.header.set_agent_status(status)
	pane.header.set_status_strip_shown(status_strips.has(key) and status_strips[key].visible)


## Desktop title actions follow the pointer to the topmost pane's title row.
func _update_header_hover(sheet_point: Vector2) -> void:
	var hovered := window_at(sheet_point) if sheet_point.is_finite() else ""
	if not hovered.is_empty():
		var pane: Control = panes[hovered]
		if (pane.get_transform().affine_inverse() * sheet_point).y >= pane.body.position.y:
			hovered = ""
	if hovered == _hovered_header: return
	if panes.has(_hovered_header) and is_instance_valid(panes[_hovered_header]):
		panes[_hovered_header].header.set_hovered(false)
	_hovered_header = hovered
	if not hovered.is_empty(): panes[hovered].header.set_hovered(true)


func _enter_tree() -> void:
	RenderUpdates.add_draw_hook(_sync_video_layers)


func _exit_tree() -> void:
	RenderUpdates.remove_draw_hook(_sync_video_layers)
	_disconnect_projection_world()
	if is_instance_valid(_status_graph): _status_graph.changed.disconnect(_agent_status_changed)
	_status_graph = null
	for key in _status_sources:
		if is_instance_valid(_status_sources[key]):
			_status_sources[key].snapshot_changed.disconnect(_resource_status_changed.bind(key))
	_status_sources.clear()


## Registered pane mods (docs/developers/automation-and-extensions/mods.md), one copy of each per pane, sized to
## their content; the workspace only places the resulting strip.
func create_status_strip(key: String) -> Control:
	var mods: Node = _mods()
	var strip: Control = mods.create_pane_strip(host, key) if mods != null else Control.new()
	# Hover shows the badge's tooltip; the strip has no click handlers, so
	# presses still reach the pane under it.
	strip.mouse_filter = Control.MOUSE_FILTER_PASS
	strip.focus_mode = Control.FOCUS_NONE
	return strip


## Keep usable locations; otherwise slide to the nearest clear point on the
## same edge before changing edges. Empty means no unobstructed on-screen
## position exists; never fall back over stdout.
static func place_status_strips(
	desired: Array[Rect2],
	bounds: Rect2,
	owners: Array[Rect2],
	obstacles: Array[Rect2] = [],
	ports: Array[Rect2] = [],
	previous: Array[Rect2] = [],
) -> Array[Rect2]:
	return Layout._core().status_place(desired, bounds, owners, obstacles, ports, previous)


## Geometry policy is shared with native frontends; this boundary uses Godot values.
static func carry_status_strip(rect: Rect2, old_owner: Rect2, owner: Rect2, extent: Vector2) -> Rect2:
	return Layout._core().status_carry(rect, old_owner, owner, extent)


func _pane_screen_rect(pane: Control) -> Rect2:
	var rect := Rect2()
	var first := true
	# Include edge midpoints for the curved world sheet, not just its corners.
	for x in 3:
		for y in 3:
			var point := view_point(pane.get_transform() * (pane.size * Vector2(x * 0.5, y * 0.5)))
			if not point.is_finite():
				continue
			rect = Rect2(point, Vector2.ZERO) if first else rect.expand(point)
			first = false
	return rect


## Titles compensate navigation zoom inside the sheet, so typing motion and
## depth of field still affect them together with the pane.
func _presentation_settled() -> bool:
	return host.world.fly_dur <= 0.0 and host.world.tab_fx_t < 0.0


func _update_compact_headers(for_transition := false) -> void:
	if not is_inside_tree() or host == null or not is_instance_valid(host.world):
		return
	for key in status_strips.keys():
		if not panes.has(key) or not is_instance_valid(panes[key]):
			pane_status.erase(key)
			status_strips[key].queue_free()
			status_strips.erase(key)
			_status_placements.erase(key)
	for key in pane_titles.keys():
		if not panes.has(key) or not is_instance_valid(panes[key]):
			pane_titles[key].queue_free()
			pane_titles.erase(key)
	var settled: bool = for_transition or _presentation_settled()
	var navigation_transform := _status_navigation_transform()
	for key in panes:
		var pane: Control = panes[key]
		if not is_instance_valid(pane) or not pane.is_node_ready():
			continue
		# view_point falls back to sheet coordinates when a projection is unavailable.
		# Validate layout here; only the title bounds need projecting.
		var eligible: bool = settled and pane.visible and pane.get_transform().is_finite() \
			and pane.size.is_finite() and is_finite(pane.body.position.y)
		# Layout responds to deliberate navigation, never typing magnification.
		var header_height := navigation_transform.basis_xform(Vector2(0, pane.body.position.y)).length()
		var compact: bool = eligible and header_height < COMPACT_HEADER_THRESHOLD
		if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
			# Each client compares against its own fitted footprint, not server pixels.
			var area := content_rect().intersection(Rect2(Vector2.ZERO, size))
			var fit := minf(area.size.x / pane.size.x, area.size.y / pane.size.y) * .9
			var shown := navigation_transform.x.length()
			compact = eligible and shown < fit * .5
		if not pane_titles.has(key):
			var title := preload("res://scenes/mods/PaneTitle.gd").new()
			title.name = "PaneTitle"
			title.mouse_filter = Control.MOUSE_FILTER_IGNORE
			title.clip_text = true
			title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			title.add_theme_font_override("font", pane.handle.get_theme_font("font"))
			title.add_theme_font_size_override("font_size", pane.handle.get_theme_font_size("font_size"))
			title.add_theme_color_override("font_color", pane.handle.get_theme_color("font_color"))
			pane.add_child(title)
			pane_titles[key] = title
		var title: Label = pane_titles[key]
		var navigation := [host.world.get_instance_id(), host.world.active, size, overview, navigation_center, navigation_zoom, pane.position, pane.size, host.world.pose_eye, host.world.pose_forward, host.world.pose_up, host.world.pose_half_x]
		if title.get_meta("navigation", []) != navigation:
			title.scale = Vector2.ONE * host.world.title_navigation_scale(pane.position)
			title.set_meta("navigation", navigation)
		if pane.touch_header:
			pane.header.scale = title.scale
			var header_width := maxf(0, pane.size.x - 16) / title.scale.x
			pane.header.set_available_width(header_width)
			pane.header.size = Vector2(header_width, 30)
		var title_height := title.get_theme_font("font").get_height(title.get_theme_font_size("font_size"))
		pane.set_compact_header(compact, title_height * title.scale.y)
		var handle_rect: Rect2 = pane.title_handle_rect()
		title.position = Vector2(maxf(2.0, handle_rect.position.x), 1.0)
		title.size = Vector2(maxf(0.0, minf(pane.size.x - 2.0, handle_rect.end.x) - title.position.x) / title.scale.x,
			title_height)
		title.text = pane.title_for_label(title)
		title.tooltip_text = pane.handle.tooltip_text
		title.visible = eligible and pane.size.y >= title.position.y + title.size.y * title.scale.y \
			and Rect2(Vector2.ZERO, size).intersects(title_screen_rect(title))
		pane.handle.modulate.a = 0.0
		# Reserve room locally; no inverse camera samples or PTY resizing needed.
		var inset := 0.0
		if title.visible and host.is_terminal_pane(key):
			inset = maxf(0.0, title.position.y + title.size.y * title.scale.y + title.scale.y - pane.body.position.y)
		if pane.touch_header and not compact:
			inset = maxf(inset, pane.header.size.y * pane.header.scale.y - pane.body.position.y)
		pane.set_title_inset(inset)
	_update_status_strips(for_transition)


## Bake readable status placement in the deliberate navigation frame. The live
## camera then tilts, magnifies and blurs this canvas with the rest of the sheet.
func _status_navigation_transform() -> Transform2D:
	var navigating := uses_navigation_camera()
	var zoom := maxf(navigation_zoom, .01) if navigating else 1.0
	var center := navigation_center if navigating else canvas_size() * .5
	return _status_transform(center, zoom)


func _status_transform(center: Vector2, zoom: float) -> Transform2D:
	var scale := size / canvas_size().max(Vector2.ONE) * zoom
	return Transform2D(Vector2(scale.x, 0), Vector2(0, scale.y), size * .5 - center * scale)


func _update_status_strips(for_transition := false) -> void:
	if not _status_motion.is_empty() and not for_transition: return
	if for_transition:
		# Session topology and agent identity can arrive in the same frame.
		# Measure the current mod tree before freezing its size and placement;
		# otherwise the newly added agent row is clipped out of the capture.
		for key in status_strips:
			_refresh_status(key)
			_measure_status_strip(status_strips[key])
	var settled: bool = for_transition or _presentation_settled()
	_layout_status_strips(_status_navigation_transform(), settled)


func _measure_status_strip(strip: Control) -> void:
	if strip.has_method("render_now"):
		strip.render_now()
	else:
		for child in strip.get_children():
			if child is Control: _measure_status_strip(child)


func _has_session_status(key: String) -> bool:
	var id := int(key.substr(1))
	return not host.chromiums.has(id) or host.chromiums[id].main_window


func _layout_status_strips(mapping: Transform2D, settled: bool) -> void:
	# The visible content area, not the whole foreground: docked panels cover
	# its sides, and a strip placed under one is cut off.
	var bounds := viewport_content_rect()
	var snapshot: Array = [host.world.get_instance_id(), host.world.active, mapping, bounds, settled]
	# Only pane stacking affects occlusion. Raising a pane past paint-only
	# siblings (for example while typing) must not invalidate status placement.
	var pane_order: Array[String] = []
	for child in canvas_root.get_children():
		if _is_current_pane(child): pane_order.append(child.key)
	snapshot.append(pane_order)
	for key in panes:
		var pane: Control = panes[key]
		if not is_instance_valid(pane) or not pane.is_node_ready(): continue
		var minimum: Vector2 = status_strips[key].get_combined_minimum_size() if status_strips.has(key) else Vector2.ZERO
		snapshot.append([key, pane.get_rect(), pane.visible, pane.body.position.y, minimum, _has_session_status(key)])
	var port_rects: Array[Rect2] = []
	for output in [false, true]:
		for port: Control in agent_links.sockets(output).values():
			if port.is_visible_in_tree():
				# Use the socket's authored anchor and fixed hit-box offset. Its
				# current screen position includes the temporary camera effects.
				var anchor: Vector2 = port.get_meta("sheet_anchor")
				var offset: Vector2 = port.get_meta("anchor_offset")
				port_rects.append(Rect2(mapping * anchor + offset, port.size).grow(4))
	snapshot.append(port_rects)
	if snapshot == _status_layout_snapshot: return
	_status_layout_snapshot = snapshot
	status_layout_updates += 1
	var keys: Array[String] = []
	var desired: Array[Rect2] = []
	var owners: Array[Rect2] = []
	var previous: Array[Rect2] = []
	var obstacles: Array[Rect2] = []
	for pane in panes.values():
		if is_instance_valid(pane) and pane.visible and pane.is_node_ready():
			obstacles.append(mapping * pane.get_rect())
	for key in panes:
		var pane: Control = panes[key]
		if not is_instance_valid(pane) or not pane.is_node_ready(): continue
		if status_strips.has(key): status_strips[key].modulate.a = 1.0
		var show_status: bool = _has_session_status(key) and settled and pane.visible and pane.body.position.y * mapping.y.length() < STATUS_STRIP_THRESHOLD
		if not show_status:
			if status_strips.has(key): status_strips[key].hide()
			continue
		if not status_strips.has(key):
			var strip := create_status_strip(key)
			strip.z_index = 6
			canvas_root.add_child(strip)
			status_strips[key] = strip
			strip.minimum_size_changed.connect(_invalidate_headers)
			_refresh_status(key)
			# Measure now: placement below needs the strip's extent this frame.
			_measure_status_strip(strip)
		var header_center: Vector2 = pane.position + Vector2(pane.size.x * 0.5, HEADER_HEIGHT * 0.5)
		var frame: Rect2 = mapping * pane.get_rect()
		var on_screen: bool = (
			Rect2(Vector2.ZERO, size).intersects(frame)
			and window_at(header_center) == key
		)
		var strip: Control = status_strips[key]
		strip.visible = show_status and on_screen
		if not strip.visible:
			continue
		# Use the requested extent for geometry. Container layout can round its
		# actual size by a subpixel after scaling; never feed that into history.
		var extent := Vector2(
			maxf(1, strip.get_combined_minimum_size().x),
			maxf(44, strip.get_combined_minimum_size().y),
		)
		strip.size = extent
		keys.append(key)
		owners.append(frame)
		var saved: Dictionary = _status_placements.get(key, {})
		previous.append(carry_status_strip(saved.get("rect", Rect2()), saved.get("owner", Rect2()), frame, extent))
		desired.append(Rect2(Vector2(frame.position.x, frame.position.y - extent.y - 3), extent))
	var positions := place_status_strips(
		desired,
		bounds,
		owners,
		obstacles,
		port_rects,
		previous,
	)
	for index in keys.size():
		var key := keys[index]
		var strip: Control = status_strips[key]
		strip.visible = positions[index].has_area()
		if strip.visible:
			_status_placements[key] = {"rect": positions[index], "owner": owners[index]}
			strip.scale = positions[index].size / strip.size.max(Vector2.ONE) / mapping.get_scale()
			strip.position = mapping.affine_inverse() * positions[index].position
	for key in panes: _refresh_header_agent(key)


func _status_appearance() -> Dictionary:
	var result := {}
	for key in status_strips:
		var strip: Control = status_strips[key]
		result[key] = {"rect": Rect2(strip.position, strip.size * strip.scale),
			"alpha": strip.modulate.a if strip.visible else 0.0, "visible": strip.visible}
	return result


func _begin_status_motion(center: Vector2, zoom: float) -> void:
	var start := _status_appearance()
	var placements := _status_placements.duplicate(true)
	var snapshot := _status_layout_snapshot.duplicate(true)
	var from_mapping := _status_navigation_transform()
	var to_mapping := _status_transform(center, zoom)
	# Measure the destination once, before any animation sample. Restore the
	# displayed geometry below, and commit remembered placement only on arrival.
	_layout_status_strips(to_mapping, true)
	var end := _status_appearance()
	_status_motion = {"items": {}, "alpha": {},
		"placements": _status_placements.duplicate(true), "snapshot": _status_layout_snapshot.duplicate(true)}
	_status_placements = placements
	_status_layout_snapshot = snapshot
	for key in end:
		if not panes.has(key): continue
		var owner: Rect2 = panes[key].get_rect()
		var to: Dictionary = end[key]
		var from: Dictionary = start.get(key, {"visible": false, "alpha": 0.0})
		if not from.visible and not to.visible: continue
		# Appearing/disappearing strips stay on their chosen edge while fading;
		# their readable size and margin evolve with the navigation zoom.
		if not from.visible or not to.visible:
			var shown: Rect2 = from.rect if from.visible else to.rect
			var mapping := to_mapping if from.visible else from_mapping
			var extent: Vector2 = status_strips[key].size / mapping.get_scale()
			var hidden: Rect2 = Layout._core().status_reanchor(shown, owner, extent, Vector2.ONE * 3.0 / mapping.get_scale())
			if from.visible: to.rect = hidden
			else: from.rect = hidden
		var path: RefCounted = Layout._core().status_motion(owner, from.rect, to.rect)
		if path == null: continue
		_status_motion.items[key] = {"path": path,
			"from_alpha": from.alpha, "to_alpha": to.alpha, "visible": to.visible}
	_animate_status_motion(0.0)


func _animate_status_motion(weight: float) -> void:
	for key in _status_motion.get("items", {}):
		if not status_strips.has(key): continue
		var item: Dictionary = _status_motion.items[key]
		var rect: Rect2 = item.path.sample(weight)
		var strip: Control = status_strips[key]
		strip.position = rect.position
		strip.scale = rect.size / strip.size.max(Vector2.ONE)
		strip.visible = weight < 1.0 or item.visible
		var alpha := lerpf(item.from_alpha, item.to_alpha, weight)
		_status_motion.alpha[key] = alpha
		strip.modulate.a = 0.0 if host.world.tab_fx_t >= 0.0 else alpha


func _finish_inspection(main_view: bool) -> void:
	_animate_status_motion(1.0)
	if not _status_motion.is_empty():
		_status_placements = _status_motion.placements
		_status_layout_snapshot = _status_motion.snapshot
	_status_motion = {}
	_inspect_tween = null
	if main_view: show_main(true)
	else: _invalidate_headers()


## Transition captures share the sheet coordinates of baked controls. Fixed
## overlays such as the monitor still need the displayed camera's inverse.
func control_canvas_rect(control: Control) -> Rect2:
	if control.get_viewport() == canvas:
		return control.get_global_transform() * Rect2(Vector2.ZERO, control.size)
	var at := canvas_point_at(control.position)
	return Rect2(at, canvas_point_at(control.position + control.size) - at)


func control_screen_rect(control: Control) -> Rect2:
	var rect := Rect2(view_point(control.get_global_transform() * Vector2.ZERO), Vector2.ZERO)
	for corner in [Vector2(control.size.x, 0), control.size, Vector2(0, control.size.y)]:
		rect = rect.expand(view_point(control.get_global_transform() * corner))
	return rect


func title_screen_rect(title: Label) -> Rect2:
	return control_screen_rect(title)


func _compact_header_at(point: Vector2) -> String:
	for index in range(canvas_root.get_child_count() - 1, -1, -1):
		var child := canvas_root.get_child(index)
		if _is_current_pane(child) and pane_titles.has(child.key):
			var title: Label = pane_titles[child.key]
			if title.visible and title_screen_rect(title).has_point(point):
				# A readable title can overlap an action after projection. Buttons
				# win on press as well as hover; never turn their click into a drag.
				if not child.header.action_at(canvas_point_at(point)).is_empty(): return ""
				return child.key
	return ""


static func spans_main_area(rect: Rect2, area: Rect2) -> bool:
	if not area.grow(1.0).encloses(rect):
		return false
	return (
		(absf(rect.position.x - area.position.x) <= 1.0 and absf(rect.end.x - area.end.x) <= 1.0)
		or (absf(rect.position.y - area.position.y) <= 1.0 and absf(rect.end.y - area.end.y) <= 1.0)
	)


func toggle_fit_pane(key: String) -> void:
	if not pane_rects.has(key):
		return
	host.focus_pane(key)
	_toggle_fit_frame(key, pane_rects[key], _inspection_target(key), _inspection_target(key, 0.3))


func _toggle_fit_frame(key: String, rect: Rect2, target: Dictionary, fallback: Dictionary = {}) -> void:
	var tab: int = host.workspace_layout.active
	var previous := _fit_return
	# Programmatic navigation may replace a settled view without using the
	# gesture helpers. Retain endpoints only while animating or at that endpoint.
	if not previous.is_empty() and not (_inspect_tween != null and _inspect_tween.is_running()):
		var endpoint: Dictionary = previous.target
		if navigation_center.distance_to(endpoint.center) > 0.01 or absf(navigation_zoom - endpoint.zoom) > 0.0001:
			previous = {}
	_cancel_main_magnet()
	var was_main := not overview
	_begin_navigation()
	_fit_return = { }
	if (
			previous.get("key", "") == key and previous.get("tab", -1) == tab \
				and previous.get("rect") == rect
		and previous.get("size") == size
	):
		# Swap intended endpoints, never the currently displayed tween sample.
		# Keep both ends even while returning so repeated presses only reverse.
		var destination := {"center": previous.center, "zoom": previous.zoom, "main": previous.main}
		var return_view: Dictionary = previous.target
		previous.center = return_view.center
		previous.zoom = return_view.zoom
		previous.main = return_view.main
		previous.target = destination
		_fit_return = previous
		_animate_inspection(destination.center, destination.zoom, destination.main)
		return
	previous = {
		"key": key,
		"tab": tab,
		"rect": rect,
		"size": size,
		"center": navigation_center,
		"zoom": navigation_zoom,
		"main": was_main,
	}
	# A fresh session may already be fitted. Give its first toggle a useful
	# return view instead of animating from Main Area back to Main Area.
	if (
		not fallback.is_empty() and navigation_center.distance_to(target.center) < 1.0
		and absf(navigation_zoom - target.zoom) < 0.001
	):
		target = fallback
	previous.target = target
	_animate_inspection(target.center, target.zoom, target.main)
	_fit_return = previous


## Keyboard focus can reach every shown pane, including outside Main View.
## At Main View's zoom, panes inside its bounds always use the exact Main frame.
## Other zoom levels retain the cursor/visibility-based reveal policy.
func reveal_navigation_target(key: String) -> void:
	if not pane_rects.has(key): return
	# A second focus change supersedes an unfinished reveal, even if its new
	# target is already readable at the current animation sample.
	_cancel_inspect()
	var main := main_frame()
	# Use deliberate navigation zoom, not transient typing magnification. Main
	# framing depends on current geometry/zoom, never how the camera got here.
	var stable := {"center": navigation_center, "zoom": navigation_zoom} if overview else main
	if is_equal_approx(float(stable.zoom), float(main.zoom)) and content_rect().grow(1.0).encloses(pane_rects[key]):
		if not overview: return # Already Main; leave typing effects alone.
		_fit_return = {}
		_cancel_main_magnet()
		_animate_inspection(main.center, main.zoom, true)
		return
	var center := canvas_point_at(size * 0.5)
	var zoom: float = maxf((host.world._navigation_camera_zoom() if uses_navigation_camera() else host.world.fx_cam_zoom * host.world.gesture_zoom) if host.world != null else 1.0, 0.01)
	# Work in layout pixels, independent of transient tilt and pane animation.
	var viewport: Rect2 = workspace_region().canvas_rect(center, zoom)
	var cursor := Rect2()
	if host.is_terminal_pane(key):
		var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
		if not pair.is_empty() and pair.term.get_cursor_cell().x >= 0:
			var term: Control = pair.term
			var scale_value := terminal_scale(key)
			var cell_size: Vector2 = term.get_cell_size() * scale_value
			var anchor: Vector2 = terminal_origin(key) + (term.position + term.get_cursor_anchor_local()) * scale_value
			# The terminal exposes the IME anchor at the cell's bottom-left.
			cursor = Rect2(anchor - Vector2(0, cell_size.y), cell_size)
	var delta: Vector2 = Layout._core().navigation_reveal(viewport, pane_rects[key], cursor, 24.0 / zoom)
	if delta.is_zero_approx(): return
	# Temporary typing magnification must not become the saved navigation zoom.
	# Test the displayed frame above, but aim using the user's stable view.
	var stable_zoom: float = maxf(stable.zoom, 0.01)
	var stable_viewport: Rect2 = workspace_region().canvas_rect(stable.center, stable_zoom)
	delta = Layout._core().navigation_reveal(stable_viewport, pane_rects[key], cursor, 24.0 / stable_zoom)
	if delta.is_zero_approx(): return
	_fit_return = {}
	_cancel_main_magnet()
	overview = true
	navigation_center = stable.center
	navigation_zoom = stable_zoom
	_animate_inspection(navigation_center + delta, navigation_zoom, false)


func inspect_pane(key: String) -> void:
	_fit_return = { }
	_cancel_main_magnet()
	if not pane_rects.has(key):
		return
	host.focus_pane(key)
	_begin_navigation()
	var target := _inspection_target(key)
	_animate_inspection(target.center, target.zoom, target.main)


## Closing selects a neighbor; it is neither a fit command nor typing input.
## Leave the user's pointer where it is when focus and camera change.
func pan_after_close(key: String, origin: Dictionary) -> void:
	if not pane_rects.has(key):
		return
	_fit_return = { }
	_cancel_main_magnet()
	# Staying inside Main View must keep its camera, including an ongoing typing
	# zoom.
	#
	# Starting navigation here would save that temporary zoom/pan as the base for
	# every later animation instead of returning to the main framing.
	if not origin.overview and content_rect().grow(1.0).encloses(pane_rects[key]):
		overview = false
		var main := main_frame()
		navigation_center = main.center
		navigation_zoom = main.zoom
		_apply_navigation()
		return
	if origin.overview:
		overview = true
		navigation_center = origin.center
		navigation_zoom = origin.zoom
	else:
		_begin_navigation()
	var target: Vector2 = pane_rects[key].get_center()
	_animate_inspection(target, navigation_zoom, false)


static func fit_frame(rect: Rect2, visible: Rect2, viewport_size: Vector2, coverage: float) -> Dictionary:
	var region := preload("res://scenes/WorkspaceRegion.gd").new()
	region.configure(viewport_size, Vector4(visible.position.x, visible.position.y,
		viewport_size.x - visible.end.x, viewport_size.y - visible.end.y))
	return region.fit(rect, coverage)

func main_frame() -> Dictionary:
	return workspace_region().fit(content_rect())

## Intentional framing, not temporary typing effects or camera drift. Main's
## outline disappears only when both navigation pan and zoom match its fit.
func main_boundary_visible() -> bool:
	if not overview: return false
	var main := main_frame()
	return navigation_center.distance_to(main.center) > .01 or not is_equal_approx(navigation_zoom, float(main.zoom))


func uses_navigation_camera() -> bool:
	if overview: return true
	var target := main_frame()
	return absf(float(target.zoom) - 1.0) > 0.0001 or Vector2(target.center).distance_to(size * 0.5) > 0.01

func _inspection_target(key: String, coverage := 0.9) -> Dictionary:
	var rect: Rect2 = pane_rects[key]
	var main_area := content_rect()
	var visible := viewport_content_rect()
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key)).get("tree", {})
	var bounds := Layout.tiling_area(tree, main_area) if tree.get("tiling", false) else main_area
	var main_view := coverage == 0.9 and spans_main_area(rect, bounds)
	var target := fit_frame(main_area if main_view else rect, visible, size, 1.0 if main_view else coverage)
	target.main = main_view
	return target


func _animate_inspection(target_center: Vector2, target_zoom: float, main_view: bool) -> void:
	var start_center := navigation_center
	var start_zoom := navigation_zoom
	_begin_status_motion(target_center, target_zoom)
	_inspect_tween = create_tween()
	_inspect_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_inspect_tween.tween_method(
		func(weight: float):
			# Animated navigation changes the same crop as a pinch. Keep its
			# render targets until the camera settles instead of reallocating
			# the canvas and terminal textures at every tween sample.
			begin_navigation_render()
			navigation_center = start_center.lerp(target_center, weight)
			navigation_zoom = exp(lerpf(log(start_zoom), log(target_zoom), weight))
			_apply_navigation()
			_animate_status_motion(weight),
		0.0,
		1.0,
		0.3,
	)
	_inspect_tween.finished.connect(_finish_inspection.bind(main_view))


func _bind_projection_world() -> void:
	if _projection_world == host.world:
		return
	_disconnect_projection_world()
	_projection_world = host.world
	if is_instance_valid(_projection_world):
		if _projection_world.has_signal("workspace_projection_changed"):
			_projection_world.workspace_projection_changed.connect(_projection_changed)
		if _projection_world.has_signal("workspace_typed"):
			_projection_world.workspace_typed.connect(_typing_started)
	_projection_changed()


func _disconnect_projection_world() -> void:
	if is_instance_valid(_projection_world):
		if _projection_world.has_signal("workspace_projection_changed"):
			_projection_world.workspace_projection_changed.disconnect(_projection_changed)
		if _projection_world.has_signal("workspace_typed"):
			_projection_world.workspace_typed.disconnect(_typing_started)
	_projection_world = null
	_typing_timer.stop()
	physics_typing = false
	_typing_tab = -1
	_reset_pane_zoom()


## World animation owns projection changes. Coalesce its camera/sheet updates
## with container layout notifications after the final pose for this frame.
func _projection_changed() -> void:
	_raster_dirty = true
	_links_dirty = true
	_invalidate_headers()


func _invalidate_headers() -> void:
	_headers_dirty = true
	if _presentation_pending or not is_inside_tree():
		return
	_presentation_pending = true
	if _last_presentation_frame == Engine.get_process_frames():
		get_tree().process_frame.connect(_flush_presentation_updates, CONNECT_ONE_SHOT)
	else:
		_flush_presentation_updates.call_deferred()


func _flush_presentation_updates() -> void:
	_last_presentation_frame = Engine.get_process_frames()
	if not is_inside_tree() or not is_instance_valid(host) or not host.presentation_active:
		_presentation_pending = false
		return
	if _raster_dirty:
		_raster_dirty = false
		update_raster_region()
	if _links_dirty:
		_links_dirty = false
		_sync_chromium_links()
	_headers_dirty = false
	_update_compact_headers()
	_presentation_pending = false
	# Header/container layout can synchronously invalidate the new presentation.
	# Drain it once more instead of losing that update inside the current pass.
	if _headers_dirty or _raster_dirty or _links_dirty:
		_invalidate_headers()


func _typing_started() -> void:
	_typing_tab = host.workspace_layout.active
	_typing_timer.start()
	if is_instance_valid(host.world) and host.world.fx_enabled and host.effect_control.allows("pane_zoom") and panes.has(host.pane_focus) and host.world.fx_cfg.typing_settings().pane_zoom > 1.0:
		if _pane_zoom_tab != host.workspace_layout.active: _reset_pane_zoom()
		_pane_zoom_tab = host.workspace_layout.active
		_pane_zoom.pulse(host.pane_focus, float(host.world.fx_cfg.behavior.idle_after))
		raise_window(host.pane_focus)
		set_process(true)
	if not physics_typing:
		physics_typing = true
		wake_pane_physics()


func _typing_finished() -> void:
	physics_typing = false
	_typing_tab = -1
	wake_pane_physics()


func cancel_pane_zoom() -> void:
	_pane_zoom.cancel()


func cancel_typing_effects() -> void:
	cancel_pane_zoom()
	if is_instance_valid(_typing_timer): _typing_timer.stop()
	_typing_finished()


func _reset_pane_zoom() -> void:
	for key in _pane_zoom.weights:
		if panes.has(key):
			panes[key].scale = Vector2.ONE
			panes[key].pivot_offset = Vector2.ZERO
	_pane_zoom = TypingPaneZoom.new()
	_pane_zoom_tab = -1
	set_process(false)


func _apply_pane_zoom(key: String) -> void:
	if not panes.has(key) or not pane_rects.has(key): return
	var weight: float = _pane_zoom.weights.get(key, 0.0)
	var zoom := 1.0
	var bounds := Rect2()
	if weight > 0.0 and is_instance_valid(host.world):
		zoom = lerpf(1.0, host.world.fx_cfg.typing_settings().pane_zoom, weight)
		bounds = _pane_zoom_bounds(key)
	TypingPaneZoom.apply(panes[key], pane_rects[key], zoom, bounds)
	# Render every sample from canonical geometry, never the previous sample.
	# Adding offsets cumulatively sends the pane backwards and leaves it there.
	if not (panes[key]._dragging or panes[key]._resizing):
		panes[key].position = pane_rects[key].position
	if _remote_move_tab == host.workspace_layout.active and not (panes[key]._dragging or panes[key]._resizing):
		panes[key].position += Vector2(_remote_move_offsets.get(key, Vector2.ZERO)) * _remote_move_weight


## A tiled pane grows within the tiling area; others grow about their centre.
func _pane_zoom_bounds(key: String) -> Rect2:
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).get("tree", {})
	var item := Layout.find(tree, key)
	if tree.get("tiling", false) and not item.get("stashed", false) and not item.get("graph_floating", false):
		return Layout.tiling_area(tree, content_rect())
	return Rect2()


## The canvas rectangle typing pane zoom draws `key` in once its current
## animation lands; empty while the pane is not magnified.
##
## A full-width tile grows past the Main area's edges. Adaptive framing must
## contain that footprint, and must aim at the landing size rather than chase
## the animation.
func typing_zoom_rect(key: String) -> Rect2:
	if not _pane_zoom.weights.has(key) or not pane_rects.has(key) or not is_instance_valid(host.world): return Rect2()
	var focused: String = host.pane_focus if host.world.fx_enabled else ""
	var weight := maxf(_pane_zoom.weights[key], _pane_zoom.target_weight(key, focused))
	var zoom := lerpf(1.0, host.world.fx_cfg.typing_settings().pane_zoom, weight)
	return TypingPaneZoom.geometry(pane_rects[key], zoom, _pane_zoom_bounds(key))


## Animate received geometry only. Neither intermediate frames nor camera state
## mutate workspace data or generate network edits.
func animate_shared_move(previous: Dictionary) -> void:
	var current: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if previous.is_empty() or int(previous.get("id", -1)) != int(current.get("id", -2)): return
	var offsets := {}
	for key in pane_rects:
		if panes[key]._dragging or panes[key]._resizing: continue
		var old := Layout.find(previous.get("tree", {}), key)
		var next := Layout.find(current.get("tree", {}), key)
		if old.is_empty() or next.is_empty(): continue
		var delta: Vector2 = old.get("rect", Rect2()).position - next.get("rect", Rect2()).position
		if delta.length_squared() > 0.01: offsets[key] = delta
	var bends := {}
	var before: Dictionary = previous.get("graph_visual", {}).get("reroutes", {})
	var after: Dictionary = current.get("graph_visual", {}).get("reroutes", {})
	for id in before:
		if after.has(id) and before[id].position != after[id].position:
			bends[id] = before[id].position - after[id].position
	if offsets.is_empty() and bends.is_empty(): return
	if _remote_move_tween != null: _remote_move_tween.kill()
	_remote_move_offsets = offsets
	_remote_move_tab = host.workspace_layout.active
	agent_links.tools.remote_offsets = bends
	agent_links.tools.remote_tab = _remote_move_tab
	_remote_move_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var render := func(weight: float):
		_remote_move_weight = weight
		agent_links.tools.remote_weight = weight
		for key in _remote_move_offsets:
			_apply_pane_zoom(key)
		_sync_chromium_links()
		_invalidate_headers()
	render.call(1.0)
	_remote_move_tween.tween_method(render, 1.0, 0.0, 0.15)


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("WorkspaceView", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	_advance_wheel_zoom(dt)
	if not is_instance_valid(host) or _pane_zoom_tab != host.workspace_layout.active:
		_reset_pane_zoom()
		if _wheel_zoom != 0.0: set_process(true)
		return
	var world: Node = host.world
	var focused: String = host.pane_focus if is_instance_valid(world) and world.fx_enabled else ""
	var behavior: Dictionary = world.fx_cfg.behavior if is_instance_valid(world) else {}
	var changed := _pane_zoom.advance(dt, focused, float(behavior.get("enter_duration", 0.5)), float(behavior.get("leave_duration", 1.5)))
	for key in changed:
		_apply_pane_zoom(key)
		if panes.has(key): panes[key]._resize_terminal_preview()
	if not changed.is_empty():
		_links_dirty = true
		_invalidate_headers()
	if _pane_zoom.weights.is_empty() and _wheel_zoom == 0.0: set_process(false)


## Wheel notches ease out like a trackpad pinch instead of jumping: each notch
## adds to a pending zoom, spent exponentially toward the pointer it turned at.
const WHEEL_ZOOM_STEP := 1.15
## Time constant: about 95% of a notch lands within three of these.
const WHEEL_ZOOM_TIME := 0.05
## Pending natural-log zoom and the point it zooms about.
var _wheel_zoom := 0.0
var _wheel_zoom_at := Vector2.ZERO


func wheel_zoom(notches: float, at: Vector2) -> void:
	# Fast spinning queues at most about 20x either way, never a long glide.
	_wheel_zoom = clampf(_wheel_zoom + notches * log(WHEEL_ZOOM_STEP), -3.0, 3.0)
	_wheel_zoom_at = at
	# A notch ending inside Main's detent eases into Main instead of snapping there.
	var main_zoom := float(main_frame().zoom)
	if navigation_zoom > 0.0 and absf(navigation_zoom * exp(_wheel_zoom) - main_zoom) <= 0.05:
		_wheel_zoom = log(main_zoom / navigation_zoom)
	# The first frame's share lands at once, so a notch responds without delay.
	_advance_wheel_zoom(1.0 / 60.0)
	set_process(true)


func _cancel_wheel_zoom() -> void:
	_wheel_zoom = 0.0


func _advance_wheel_zoom(dt: float) -> void:
	if _wheel_zoom == 0.0: return
	if (
		not is_instance_valid(host) or not moving.is_empty() or not tile_resize.is_empty()
		or not host.application.drag.is_empty()
		or (host.world != null and (host.world.fly_dur > 0.0 or host.world.tab_fx_t >= 0.0))
	):
		_wheel_zoom = 0.0
		return
	var step := _wheel_zoom * (1.0 - exp(-maxf(dt, 0.0) / WHEEL_ZOOM_TIME))
	if absf(_wheel_zoom - step) < 0.0005:
		step = _wheel_zoom
	_wheel_zoom -= step
	# The detent applies once, where the notch lands.
	_zoom_about(exp(step), _wheel_zoom_at, _wheel_zoom == 0.0)


func _chromium_owners() -> Dictionary:
	var owners := { }
	for id in host.chromiums:
		var owner_id: int = host.chromiums[id].owner_id
		if owner_id != id: owners["%%%d" % id] = "%%%d" % owner_id
	for id in host.sessions:
		var owner_id: int = host.sessions[id].term.get_meta("filetree_owner", -1)
		if owner_id >= 0: owners["%%%d" % id] = "%%%d" % owner_id
		# A pane started by `gft pane run` hangs off its parent like a chromium or filetree.
		var parent_id: int = host.sessions[id].term.get_meta("spawned_by", -1)
		if owner_id < 0 and parent_id >= 0 and host.sessions.has(parent_id): owners["%%%d" % id] = "%%%d" % parent_id
	return owners


func set_connection_transition(transitioning: bool) -> void:
	# Screen-space sockets must yield to the captured graph during flight.
	agent_links.modulate.a = 0.0 if transitioning else 1.0
	# Wire layers are reparented beneath panes, outside their overlay controls.
	# Only the captured transition layers should draw during a tab change.
	agent_links.wire_layer.visible = not transitioning
	agent_links.marker_layer.visible = not transitioning
	chromium_links.wire_layer.visible = not transitioning
	for key in status_strips:
		status_strips[key].modulate.a = 0.0 if transitioning else float(_status_motion.get("alpha", {}).get(key, 1.0))


func _sync_chromium_links() -> void:
	set_connection_transition(host.world != null and host.world.tab_fx_t >= 0.0)
	chromium_links.visible_area = content_rect()
	var visual_rects := pane_rects.duplicate()
	for key in visual_rects:
		if panes.has(key): visual_rects[key] = panes[key].get_transform() * Rect2(Vector2.ZERO, panes[key].size)
	var graph_edges: Array = host.agent_api.graph.edges.values() if host.agent_api != null else []
	chromium_links.sync(visual_rects, _chromium_owners(), view_point, pane_rects, graph_edges)
	if host.agent_api != null:
		agent_links.graph = host.agent_api.graph
		agent_links.tools.view = self
		agent_links.sync(visual_rects, host.agent_api.graph.edges.values(), view_point, is_overview(), pane_rects)


func physics_enabled() -> bool:
	return host.workspace_layout.tab(host.workspace_layout.active).get("tree", { }).get(
		"physics",
		true,
	)


func toggle_physics() -> void:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.is_empty():
		return
	group.tree["physics"] = not physics_enabled()
	pane_physics.reset()
	wake_pane_physics()
	host.ui_changed.emit()


func wake_pane_physics() -> void:
	if host != null:
		set_physics_process(physics_enabled())


func anchor_physics_pane(key: String) -> void:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
	if not group.is_empty():
		# Latest explicit placement wins; other panes yield only on collision.
		group.tree["physics_anchor"] = key
	wake_pane_physics()


func _physics_process(dt: float) -> void:
	if host == null or not is_node_ready() or not physics_enabled():
		return
	if physics_tab != host.workspace_layout.active:
		physics_tab = host.workspace_layout.active
		pane_physics.reset()
	# Transfers, tile divider edits and flight captures own their whole layout.
	if host.layout_transaction or not tile_resize.is_empty() or not host.application.drag.is_empty():
		return
	var pinned := { }
	if not moving.is_empty():
		pinned[moving] = true
	for key in panes:
		if panes[key]._pressed or panes[key]._resizing:
			pinned[key] = true
	# A held content click pins its pane without stopping its neighbours.
	if _held != 0 and not host.pane_focus.is_empty():
		pinned[host.pane_focus] = true
	var world: Node = host.world
	if world != null and (world.fly_dur > 0 or world.tab_fx_t >= 0):
		return
	# Keep a typing terminal steady while the rest of the layout continues.
	if physics_typing:
		pinned[host.pane_focus] = true
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.is_empty():
		return
	var movable := { }
	var anchor: String = group.tree.get("physics_anchor", "")
	if pane_rects.has(anchor):
		# Connections travel together across tabs, but each floating pane must
		# yield independently to contact inside its workspace.
		pinned[anchor] = true
	var items := { }
	for item in Layout.windows(group.tree):
		items[item.pane] = item
	for key in pane_rects:
		if pinned.has(key):
			continue
		var item: Dictionary = items[key]
		if item.get("stashed", false) or item.get("graph_floating", false) or not group.tree.get(
				"tiling",
				false,
			):
			movable[key] = item.get("stashed", false)
	var next := pane_physics.step(pane_rects, movable, content_rect(), dt, reachable_rect)
	if pane_physics.sleeping:
		set_physics_process(false)
	if next == pane_rects:
		return
	for key in movable:
		if pane_rects[key] == next[key]:
			continue
		pane_rects[key] = next[key]
		items[key]["rect"] = next[key]
		panes[key].position = next[key].position
		_apply_pane_zoom(key)
		panes[key]._resize_terminal_preview()
		# A tiling preview must not restore stale stash positions on release.
		if not preview_plan.is_empty() and key not in preview_plan.incoming:
			var preview_item := Layout.find(preview_plan.tree, key)
			if not preview_item.is_empty() and preview_item.get("stashed", false):
				preview_item["rect"] = next[key]
				preview_plan.rectangles[key] = next[key]
				layout_preview.queue_redraw()
	_sync_chromium_links()
	_invalidate_headers()


## Canvas pixels, which are the windows' layout coordinates, under a point of
## this view, through the displayed camera.
func canvas_point_at(local: Vector2) -> Vector2:
	if host.world != null and host.world.has_method('sheet_point_at'):
		var point: Vector2 = host.world.sheet_point_at(local / size.max(Vector2.ONE))
		if point.is_finite():
			return point
	return local


## Window-layout coordinates under a desktop point.
func layout_point(screen: Vector2) -> Vector2:
	return canvas_point_at(ScreenSpace.into(self, screen))


## Where a canvas point is drawn in this view (the inverse of canvas_point_at).
func view_point(point: Vector2) -> Vector2:
	if host.world != null and host.world.has_method('sheet_window_fraction'):
		var fraction: Vector2 = host.world.sheet_window_fraction(point)
		if fraction.is_finite():
			return fraction * size
	return point


## A world with set_video_layers() composites Chromium pages beneath this
## canvas, where their panes cut holes (WorkspacePane.set_video_layer). Runs at
## frame_pre_draw, after RenderUpdates.before_draw() presented page frames.
func _sync_video_layers() -> void:
	if not is_instance_valid(host) or not canvas.is_inside_tree(): return
	var world: Node = host.world
	var layered: bool = is_instance_valid(world) and world.has_method("set_video_layers") and host.presentation_active
	var texels := canvas.get_final_transform()
	var geometry := {}
	var changed := false
	for pane: Control in panes.values():
		var layer: Dictionary = pane.video_layer_geometry(texels) if layered else {}
		if not layer.is_empty():
			geometry[pane] = layer
		elif pane.video_layer:
			changed = pane.set_video_layer(false) or changed

	if layered:
		# Only drawable pages compete for compositor slots. Preserve draw order
		# even when a previously accepted page moves behind the slot limit.
		var pages := geometry.keys()
		pages.sort_custom(func(a: Control, b: Control) -> bool:
			return a.z_index > b.z_index or (a.z_index == b.z_index and a.get_index() > b.get_index()))
		var layers: Array[Dictionary] = []
		for pane in pages: layers.append(geometry[pane])
		var accepted: int = world.set_video_layers(layers)
		for i in pages.size():
			changed = pages[i].set_video_layer(i < accepted) or changed
	if changed: RenderUpdates.prepare(canvas)


## Terminal viewports render before the canvas that samples them only when
## they are its children; a window can receive terminals before it has one.
func adopt_terminal_viewports() -> void:
	for id in host.sessions:
		var vp: SubViewport = host.sessions[id].vp
		if vp.get_parent() != canvas:
			vp.reparent(canvas)


## Where a canvas point appears in the host window's viewport coordinates.
func window_point(point: Vector2) -> Vector2:
	return get_global_transform_with_canvas() * view_point(point)


## Where a terminal window's viewport sits on the canvas.
func terminal_origin(key: String) -> Vector2:
	var pane: Control = panes.get(key)
	if pane == null or not pane.is_inside_tree():
		return Vector2.ZERO
	return canvas_root.get_global_transform().affine_inverse() * (pane.body.get_global_transform() * pane.texture.position)


func terminal_scale(key: String) -> float:
	return panes[key].scale.x if panes.has(key) else 1.0


func _cancel_navigation_drag() -> void:
	_navigation_drag = false
	_navigation_press = null
	_navigation_delta = Vector2.ZERO
	pointer.mouse_default_cursor_shape = Control.CURSOR_ARROW


func _terminal_owns_modified_wheel(event: InputEvent) -> bool:
	if not event is InputEventMouseButton:
		return false
	var point := canvas_point_at(pointer.get_transform() * event.position)
	var key := window_at(point)
	if not host.is_terminal_pane(key):
		return false
	var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
	if pair.is_empty():
		return false
	var scale_value := terminal_scale(key)
	var body := Rect2(terminal_origin(key) + pair.term.position * scale_value, pair.term.size * scale_value)
	if not body.has_point(point):
		return false
	for binding in host.world.terminal_config.mouse_bindings:
		if binding.button == event.button_index and binding.modifiers == int(event.get_modifiers_mask()):
			return true
	return false


func _forward_pointer(event: InputEvent, replay_click := false) -> void:
	replay_click = replay_click or bool(event.get_meta("direct_touch", false))
	if not (event is InputEventMouse or event is InputEventGesture):
		return
	pointer.accept_event()
	if host.world != null and host.world.has_method("pointer_activity"):
		host.world.pointer_activity()
	if event is InputEventGesture:
		# Godot 4.7 dispatches every trackpad gesture twice in one frame. Acting
		# on both doubled each pinch step and each two-finger scroll.
		var signature := [
			event.get_class(),
			event.position,
			event.factor if event is InputEventMagnifyGesture else event.get("delta"),
			event.meta_pressed,
			event.ctrl_pressed,
			event.get_meta("pinch_previous") if event.has_meta("pinch_previous") else null,
			event.get_meta("pinch_center") if event.has_meta("pinch_center") else null,
			event.get_meta("touch_scroll_sequence") if event.has_meta("touch_scroll_sequence") else null,
			event.get_meta("scroll_phase") if event.has_meta("scroll_phase") else null,
			event.get_meta("momentum_phase") if event.has_meta("momentum_phase") else null,
			Engine.get_process_frames(),
		]
		if signature == _last_gesture:
			# The second delivery of one event. Forget it: a touchpad can send
			# several events with equal values within a frame (Wayland batches
			# them when a frame runs late), and each of those arrives twice too.
			_last_gesture = []
			return
		_last_gesture = signature
	pointer_screen = host.application.screen_point(
		get_viewport(),
		pointer.get_global_transform_with_canvas() * event.position,
	)
	var command: bool = event.meta_pressed or (OS.get_name() != "macOS" and event.ctrl_pressed)
	if event is InputEventMouseButton and event.pressed:
		_pinch_anchor = Vector2.INF
	var pinch_pan: bool = event is InputEventPanGesture and not command and event.delta.is_finite() and _pinch_anchor.is_finite() and Time.get_ticks_msec() - _pinch_last_msec < PINCH_IDLE_MSEC
	var scroll_zoom: bool = (
		command
		and not _terminal_owns_modified_wheel(event)
		and (
			event is InputEventPanGesture
			or (
				event is InputEventMouseButton
				and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
			)
		)
	)
	var drag_start: bool = (
		not replay_click and event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed
		and not (
			event.ctrl_pressed or event.alt_pressed or event.shift_pressed or event.meta_pressed
		)
	)
	if not replay_click and _navigation_press != null:
		if (
			event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed
		):
			var press := _navigation_press
			var was_dragging := _navigation_drag
			_cancel_navigation_drag()
			if not was_dragging:
				_forward_pointer(press, true)
				_forward_pointer(event, true)
		elif event is InputEventMouseMotion:
			if not event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
				_cancel_navigation_drag()
			else:
				_navigation_delta += event.relative
				var delta: Vector2 = event.relative
				if not _navigation_drag:
					if _navigation_delta.length() < 5.0:
						return
					_navigation_drag = true
					delta = _navigation_delta
					pointer.mouse_default_cursor_shape = Control.CURSOR_DRAG
				var at: Vector2 = pointer.get_transform() * event.position
				pan_workspace(-delta * (0.03 if OS.get_name() == "macOS" else 1.0), at)
		return
	if scroll_zoom or drag_start or pinch_pan or event is InputEventMagnifyGesture:
		if (
			not moving.is_empty() or not tile_resize.is_empty()
			or not host.application.drag.is_empty()
		):
			return
		if host.world != null and (host.world.fly_dur > 0.0 or host.world.tab_fx_t >= 0.0):
			return
		var at: Vector2 = pointer.get_transform() * event.position
		# Direct gestures take over from a wheel zoom still easing out.
		if not (event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]):
			_cancel_wheel_zoom()
		if pinch_pan:
			var previous := _pinch_anchor
			_pinch_anchor += event.delta * pinch_pan_speed
			_pinch_last_msec = Time.get_ticks_msec()
			pinch_workspace(previous, _pinch_anchor, 1.0)
		elif drag_start:
			_navigation_press = event.duplicate()
			_navigation_delta = Vector2.ZERO
		elif event is InputEventMagnifyGesture:
			# The anchor starts at the mouse and travels with shared finger pan.
			# Continuing magnification uses that imaginary point, never snaps back.
			var previous := at
			var center := at
			if event.has_meta("pinch_pan"):
				_pinch_anchor = Vector2.INF
				var to_local := get_global_transform_with_canvas().affine_inverse() * get_viewport().get_final_transform().affine_inverse()
				previous = to_local * Vector2(event.get_meta("pinch_previous"))
				center = to_local * Vector2(event.get_meta("pinch_center"))
			else:
				if not _pinch_anchor.is_finite() or Time.get_ticks_msec() - _pinch_last_msec >= PINCH_IDLE_MSEC:
					_pinch_anchor = at
				_pinch_last_msec = Time.get_ticks_msec()
				previous = _pinch_anchor
				center = _pinch_anchor
			if not is_equal_approx(event.factor, 1.0) or not previous.is_equal_approx(center):
				pinch_workspace(previous, center, event.factor)
		elif event is InputEventPanGesture:
			zoom_workspace(exp(clampf(-event.delta.y * 0.08, -1.0, 1.0)), at)
		elif event.pressed:
			var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			wheel_zoom(direction * maxf(event.factor, 1.0), at)
		return
	if event is InputEventMouseButton:
		if event.pressed:
			_held |= 1 << event.button_index
		else:
			_held &= ~(1 << event.button_index)
		wake_pane_physics()
	var forwarded: InputEvent = event.duplicate()
	var local: Vector2 = pointer.get_transform() * event.position
	var sheet_point := canvas_point_at(local)
	if event is InputEventMouse and not event.get_meta("direct_touch", false):
		_update_header_hover(sheet_point)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var pointed := window_at(sheet_point)
		if host.is_chromium_pane(pointed):
			var chromium: Node = host.chromiums.get(int(pointed.substr(1)))
			if chromium != null:
				chromium.context_menu_screen = preload("res://scenes/ScreenSpace.gd").of(pointer, event.position)
		if panes.has(pointed) and panes[pointed].secondary_split_at(sheet_point):
			return
		var title_key := _compact_header_at(local)
		if title_key.is_empty():
			var candidate := window_at(sheet_point)
			if panes.has(candidate):
				var pane: Control = panes[candidate]
				if sheet_point.y < pane.position.y + pane.body.position.y:
					title_key = candidate
		if not title_key.is_empty():
			panes[title_key].show_title_menu()
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var compact_key := _compact_header_at(local)
		if not compact_key.is_empty():
			if event.double_click:
				panes[compact_key]._cancel_drag()
				_held = 0
				toggle_fit_pane(compact_key)
			else:
				panes[compact_key].begin_header_drag(sheet_point, event.shift_pressed)
			return
		if _start_tile_resize(sheet_point, bool(event.get_meta("direct_touch", false))):
			return
	forwarded.position = canvas.canvas_transform * sheet_point
	if forwarded is InputEventMouse:
		forwarded.global_position = forwarded.position
	if forwarded is InputEventMouseMotion:
		forwarded.relative = forwarded.position - canvas.canvas_transform * canvas_point_at(
			local - event.relative
		)
	if forwarded is InputEventPanGesture and event.has_meta("touch_travel"):
		# A finger's travel across this view, measured through the camera.
		var travel: Vector2 = get_global_transform_with_canvas().affine_inverse().basis_xform(event.get_meta("touch_travel"))
		forwarded.set_meta("touch_travel", canvas.canvas_transform * canvas_point_at(local + travel) - forwarded.position)
	canvas.push_input(forwarded, true)
	if forwarded is InputEventMouseMotion:
		# Controls on the canvas choose the cursor shown over the sheet; a
		# window's edges show which way they resize it.
		var hovered := canvas.gui_get_hovered_control()
		var shape: int = (
			hovered.get_cursor_shape(
				hovered.get_global_transform_with_canvas().affine_inverse() * forwarded.position
			)
			if hovered != null
			else Control.CURSOR_ARROW
		)
		var edge := _resize_cursor(sheet_point)
		pointer.follow_terminal(hovered.get_meta("terminal_control") if hovered != null and hovered.has_meta("terminal_control") and edge < 0 else null)
		pointer.mouse_default_cursor_shape = edge if edge >= 0 else shape


func _resize_cursor(point: Vector2) -> int:
	if _held == 0:
		if not _compact_header_at(view_point(point)).is_empty():
			return Control.CURSOR_DRAG
		var dividers := dividers_at(point)
		if not dividers.is_empty():
			return divider_cursor(dividers, point)
	for pane in panes.values():
		if pane._resizing:
			return pane.resize_cursor(point)
	# A held button belongs to whatever it pressed, not to the edge it crosses.
	if _held != 0:
		return -1
	var key := window_at(canvas_root.get_global_transform().affine_inverse() * point)
	return panes[key].resize_cursor(point) if key != '' else -1


func _pointer_entered() -> void:
	# A held drag keeps the canvas entered even if the window briefly loses
	# the pointer. Re-entering must not notify the viewport a second time.
	if not _pointer_in_canvas:
		_pointer_in_canvas = true
		canvas.notify_mouse_entered()


func _pointer_left() -> void:
	pointer.follow_terminal(null)
	# Clear hover inside the canvas, unless a drag still owns the pointer.
	if _held != 0:
		return
	_update_header_hover(Vector2.INF)
	var away := InputEventMouseMotion.new()
	away.position = Vector2(-1e6, -1e6)
	away.global_position = away.position
	canvas.push_input(away, true)
	if _pointer_in_canvas:
		_pointer_in_canvas = false
		canvas.notify_mouse_exited()


func _input(event: InputEvent) -> void:
	if (
		_navigation_press != null and event is InputEventKey
		and event.pressed and event.keycode == KEY_ESCAPE
	):
		_cancel_navigation_drag()
		get_viewport().set_input_as_handled()
		return
	if not tile_resize.is_empty():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel_tile_resize()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseMotion:
			_update_tile_resize(
				canvas_point_at(
					get_global_transform_with_canvas().affine_inverse() * event.position
				)
			)
			get_viewport().set_input_as_handled()
			return
		if (
			event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed
		):
			tile_resize = { }
			agent_links.tools.finish_edit()
			_held = 0
			pointer.mouse_default_cursor_shape = Control.CURSOR_ARROW
			host.session_backend.resize_tiles(host)
			host.ui_changed.emit()
			get_viewport().set_input_as_handled()
			return
	# Escape reaches a window being dragged or resized inside the canvas.
	if event is InputEventKey and event.keycode == KEY_ESCAPE and _held != 0:
		canvas.push_input(event.duplicate(), true)
		if canvas.is_input_handled():
			get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	# Address bars and dialogs inside the canvas.
	if canvas.gui_get_focus_owner() == null:
		return
	canvas.push_input(event.duplicate(), true)
	get_viewport().set_input_as_handled()


func has_text_focus() -> bool:
	return (
		get_viewport().gui_get_focus_owner() is RichTextLabel
		or host.is_chromium_pane(host.pane_focus) or canvas.gui_get_focus_owner() != null
	)


func handle_workspace_key(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var pane: Control = panes.get(host.pane_focus)
	return pane != null and pane.chrome != null and pane.chrome.handle_shortcut(event)


func drop_zone(screen: Vector2) -> Dictionary:
	var local := ScreenSpace.into(self, screen)
	if not _foreground_rect().has_point(local):
		return { }
	var point := canvas_point_at(local)
	return {
		'tab': host.workspace_layout.active,
		'pane': '',
		'edge': '',
		'rect': Rect2(point - Vector2(80, 30), Vector2(160, 100)),
	}


var dock_insets := Vector4.ZERO # left, right, top, bottom
var _region := preload("res://scenes/WorkspaceRegion.gd").new()

func set_dock_insets(value: Vector4) -> void:
	if dock_insets.is_equal_approx(value): return
	dock_insets = value
	cancel_tile_resize()
	_refresh_after_resize.call_deferred()

func workspace_region() -> RefCounted:
	var top := _foreground_rect().position.y
	for chrome in [tab_bar, toolbar]:
		if chrome != null and chrome.is_visible_in_tree():
			top = maxf(top, chrome.get_global_rect().end.y - global_position.y)
	_region.configure(size, Vector4(dock_insets.x, top + dock_insets.z, dock_insets.y, dock_insets.w))
	return _region

func viewport_content_rect() -> Rect2:
	return workspace_region().rect()

## The main area this window offers when it sizes the shared layout, in whole
## logical pixels.
##
## The active Android client reflows the shared layout into the space above
## its keyboard and accessory bar, just as a window resize does.
func window_fit_rect() -> Rect2:
	return workspace_region().layout_rect()


func content_rect() -> Rect2:
	return host.session_backend.content_rect(host, viewport_content_rect())


## Keeps part of a window's drag handle inside the frame and its header below
## the tab bar.
##
## A pointer drag supplies the visible canvas bounds, so pan/zoom never turns
## the main-area border into a barrier. Bodies may extend outside.
func reachable_rect(key: String, rect: Rect2, bounds := Rect2()) -> Rect2:
	if not bounds.has_area():
		# Non-pointer placement in Overview may be anywhere on the canvas.
		if is_overview():
			return rect
		bounds = workspace_region().rect()
		if host.session_backend.is_remote and host.session_backend.authoritative():
			bounds = content_rect()
	var pane: Control = panes.get(key)
	var controls := 180.0
	if pane != null:
		controls = pane.header.get_combined_minimum_size().x - pane \
				.handle \
				.get_combined_minimum_size() \
				.x
	var handle := maxf(rect.size.x - controls, 1.0)
	var grab := minf(GRAB_EXTENT, handle)
	rect.position.x = clampf(rect.position.x, bounds.position.x + grab - handle, maxf(bounds.position.x + grab - handle, bounds.end.x - grab))
	var top := bounds.position.y
	rect.position.y = clampf(rect.position.y, top, maxf(top, bounds.end.y - HEADER_HEIGHT))
	return rect


func set_window_rect(key: String, rect: Rect2, resizing := false) -> void:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
	var item := Layout.find(group.get('tree', { }), key)
	if item.is_empty():
		return
	rect.size = rect.size.max(Vector2(320, 200))
	# Terminal sizing follows the requested rectangle, not a container preview.
	if resizing:
		host.session_backend.resize_pane(host, key, rect)
	if not is_overview() and not item.get("stashed", false) and not resizing:
		rect = reachable_rect(key, rect)
	item.rect = rect
	# A resize is not a drop. Reclassifying by the new center can unstash or
	# re-tile a floating pane as soon as its edge crosses the Main boundary.
	if moving != key and not resizing:
		Layout.place(group.tree, key, rect, content_rect())
	refresh()


## A window edge is being dragged: its rectangle is still a preview.
func resizing_window() -> bool:
	return panes.values().any(func(pane: Control) -> bool: return pane._resizing)


func raise_window(key: String) -> void:
	if panes.has(key):
		canvas_root.move_child(panes[key], canvas_root.get_child_count() - 1)


## A resize target may extend into empty canvas, but never across another
## pane's content. In empty gaps prefer the closest edge, then the front pane.
func resize_window_at(point: Vector2, touch := false) -> String:
	var over := window_at(point)
	if not over.is_empty():
		var pane: Control = panes[over]
		return over if pane._edge_at(pane.get_transform().affine_inverse() * point, touch) != Vector2.ZERO else ""
	if not touch: return ""
	var closest := ""
	var distance := INF
	var screen := window_point(point)
	for index in range(canvas_root.get_child_count() - 1, -1, -1):
		var child := canvas_root.get_child(index)
		if not _is_current_pane(child) or not child.visible: continue
		var local: Vector2 = child.get_transform().affine_inverse() * point
		if child._edge_at(local, true) == Vector2.ZERO: continue
		var edge: Vector2 = child.get_transform() * local.clamp(Vector2.ZERO, child.size)
		var candidate := screen.distance_to(window_point(edge))
		if candidate < distance:
			distance = candidate
			closest = child.key
	return closest


## The canvas also contains overlays and can still hold a retired pane until frame end.
func _is_current_pane(child: Node) -> bool:
	return "key" in child and panes.get(child.key) == child


## The window drawn topmost at a canvas point.
func window_at(point: Vector2) -> String:
	for index in range(canvas_root.get_child_count() - 1, -1, -1):
		var child := canvas_root.get_child(index)
		if _is_current_pane(child) and child.visible and Rect2(Vector2.ZERO, child.size).has_point(child.get_transform().affine_inverse() * point):
			return child.key
	return ''


func show_drop(zone: Dictionary) -> void:
	if zone.is_empty():
		clear_layout_preview()
	drop_hint.visible = not zone.is_empty()
	if zone.is_empty():
		return
	drop_hint.position = zone.rect.position
	drop_hint.size = zone.rect.size
	hint_text.text = zone.get('label', 'Join workspace')


func toggle_tiling() -> void:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.is_empty():
		return
	var tree: Dictionary = group.tree
	if tree.get("tiling", false):
		for key in pane_rects:
			Layout.find(tree, key)["rect"] = pane_rects[key]
	tree["tiling"] = not tree.get("tiling", false)
	if tree.tiling:
		for item in Layout.windows(tree):
			item.erase("graph_floating")
	refresh()
	host.session_backend.set_tiling(host, tree.tiling)


func resize_to_fit_main(key := "") -> void:
	if host.layout_transaction or not tile_resize.is_empty() or not moving.is_empty() or not host.application.drag.is_empty():
		return
	if key.is_empty(): key = host.pane_focus
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var item := Layout.find(group.get("tree", {}), key)
	if item.is_empty() or not item.get("shown", true): return
	if not Layout.resize_to_fit_main(group.tree, key, content_rect(), group.get("focused", "")): return
	anchor_physics_pane(key)
	refresh()
	host.session_backend.commit_workspace(host)
	host.ui_changed.emit()


func split_window(axis: String, beside := "", before := false) -> void:
	if (
		not axis in ["h", "v"] or not tile_resize.is_empty()
		or not moving.is_empty() or not host.application.drag.is_empty()
	):
		return
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.is_empty():
		return
	if beside.is_empty():
		beside = host.pane_focus
	var focused := Layout.find(group.tree, beside)
	if focused.is_empty() or not focused.get("shown", true):
		return
	# The same command splits managed tiles or spawns a floating neighbor.
	# Preserve stashed/group-floating placement and the tab's selected mode.
	host.create_terminal_window(beside, axis, before)


func show_overview() -> void:
	_fit_return = { }
	_cancel_main_magnet()
	var region := overview_region()
	navigation_center = region.get_center()
	navigation_zoom = minf(size.x / region.size.x, size.y / region.size.y)
	overview = true
	_apply_navigation()
	refresh()


func _begin_navigation() -> void:
	if overview:
		return
	navigation_center = canvas_point_at(size * 0.5)
	navigation_zoom = (host.world._navigation_camera_zoom() if uses_navigation_camera() else host.world.fx_cam_zoom * host.world.gesture_zoom) if host.world != null else 1.0
	overview = true
	_apply_navigation()


## Store intentional navigation, never an in-flight camera sample. Keeping it on
## the tab also carries the view with a reordered or detached workspace.
func save_navigation() -> void:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if not group.is_empty():
		var center := navigation_center - inset_shift / maxf(navigation_zoom, .01)
		var navigation := {
			"overview": overview,
			"center": [center.x, center.y],
			"zoom": navigation_zoom,
		}
		if group.get("navigation") != navigation:
			group.navigation = navigation
			navigation_changed.emit()


## A pause with a button/finger still held is not the end of navigation.
## Tab flights only interpolate presentation; their saved destination is ready.
func navigation_in_progress() -> bool:
	return (
		_navigation_drag or not moving.is_empty()
		or (is_instance_valid(mobile_pointer) and not mobile_pointer.gestures.fingers.is_empty())
		or (_inspect_tween != null and _inspect_tween.is_running())
	)


func restore_navigation(tab_id: int) -> void:
	_pinch_anchor = Vector2.INF
	_fit_return = { }
	_cancel_main_magnet()
	var saved: Dictionary = host.workspace_layout.tab(tab_id).get("navigation", { })
	overview = saved.get("overview", false)
	# A new tab starts at the same fitted Main Area as Cmd+Enter, including
	# when the owner's sheet differs from this frontend's viewport.
	var main := main_frame()
	if not overview:
		navigation_center = main.center
		navigation_zoom = main.zoom
		return
	var center: Array = saved.get("center", [main.center.x, main.center.y])
	navigation_zoom = saved.get("zoom", main.zoom)
	navigation_center = Vector2(center[0], center[1]) + inset_shift / maxf(navigation_zoom, .01)


func _apply_navigation() -> void:
	save_navigation()
	if host.world != null:
		host.world._apply_camera_fx()
		update_raster_region()


## Android's keyboard and compact chrome moved this view's edges from
## `previous`. Navigated content keeps its place on screen; Main View refits.
## The resize refits the camera, and saved navigation already omits the shift.
func keep_screen_position(previous: Rect2) -> void:
	var shift := get_global_rect().get_center() - previous.get_center()
	inset_shift += shift
	if overview: navigation_center += shift / maxf(navigation_zoom, .01)


func pan_workspace(delta: Vector2, at: Vector2) -> void:
	begin_navigation_render()
	_begin_magnetic_navigation()
	# Godot macOS converts native scroll pixels to pan units by multiplying .03.
	var pixels := delta * (1.0 / 0.03 if OS.get_name() == "macOS" else 1.0)
	var before := canvas_point_at(at)
	var after := canvas_point_at(at + pixels)
	navigation_center += after - before
	_apply_navigation()
	_magnetize_navigation()


func pinch_workspace(previous_center: Vector2, center: Vector2, factor: float) -> void:
	if not is_finite(factor) or factor <= 0.0:
		return
	begin_navigation_render()
	_begin_magnetic_navigation()
	# Direct manipulation: retain the sheet point under the old centroid at the
	# new centroid after scaling, then apply the same Main detent as pan/wheel.
	var anchor := canvas_point_at(previous_center)
	navigation_zoom = clampf(navigation_zoom * factor, 0.05, 6.0)
	# Only update the camera for the anchor calculation. Allocate and draw once
	# after both zoom and translation have been resolved.
	if host.world != null: host.world._apply_camera_fx()
	navigation_center += anchor - canvas_point_at(center)
	_apply_navigation()
	_magnetize_navigation()


func zoom_workspace(factor: float, at: Vector2) -> void:
	_zoom_about(factor, at, true)


## `magnetize` false leaves the Main detent to the caller: an eased wheel notch
## knows its destination and decides once, instead of sticking then jumping.
func _zoom_about(factor: float, at: Vector2, magnetize: bool) -> void:
	if not is_finite(factor) or factor <= 0.1 or factor > 10.0:
		return
	begin_navigation_render()
	_begin_magnetic_navigation()
	var anchor := canvas_point_at(at)
	navigation_zoom = clampf(navigation_zoom * factor, 0.05, 6.0)
	if host.world != null: host.world._apply_camera_fx()
	# Keep the point under the fingers fixed instead of snapping to the main area.
	navigation_center += anchor - canvas_point_at(at)
	_apply_navigation()
	if magnetize:
		_magnetize_navigation()
	else:
		_main_magnet_held = false


func _cancel_main_magnet() -> void:
	_main_magnet_held = false
	_cancel_inspect()


func _cancel_inspect() -> void:
	if _inspect_tween != null:
		_inspect_tween.kill()
		_inspect_tween = null
		_status_motion = {}
		_status_layout_snapshot.clear()
		_invalidate_headers()


func _begin_magnetic_navigation() -> void:
	_fit_return = { }
	_cancel_inspect()
	if host.world != null and host.world.has_method("interrupt_adaptive_camera") and host.world.interrupt_adaptive_camera():
		# Keep the reference already under the frozen adaptive correction.
		# Adopting the displayed zoom here would apply that correction twice.
		overview = true
	# Accumulate finger movement behind the detent so small events can escape it.
	# A new gesture starts from the visible view, never an old hidden offset.
	var now := Time.get_ticks_msec()
	if now - _main_magnet_input_ms > 300:
		_main_magnet_held = false
	_main_magnet_input_ms = now
	if _main_magnet_held:
		overview = true
		navigation_center = _main_magnet_raw_center
		navigation_zoom = _main_magnet_raw_zoom
		_apply_navigation()
	else:
		_begin_navigation()


func _magnetize_navigation() -> void:
	# Enter while fingers are moving; a wider exit band prevents boundary jitter.
	var zoom_range := 0.08 if _main_magnet_held else 0.05
	var position_range := minf(size.x, size.y) * (0.055 if _main_magnet_held else 0.035)
	var target := main_frame()
	if (
		absf(navigation_zoom - float(target.zoom)) > zoom_range
		or navigation_center.distance_to(target.center) > position_range
	):
		_main_magnet_held = false
		return
	_main_magnet_raw_center = navigation_center
	_main_magnet_raw_zoom = navigation_zoom
	show_main()
	_main_magnet_held = true


## Explicit navigation animates; internal resets and the gesture detent settle immediately.
func fit_to_main_area() -> void:
	var target := main_frame()
	target.main = true
	_toggle_fit_frame("@main", content_rect(), target)


func show_main(preserve_fit := false) -> void:
	if not preserve_fit:
		_fit_return = { }
	_cancel_main_magnet()
	if physics_typing:
		_typing_timer.stop()
		_typing_finished()
	overview = false
	var target := main_frame()
	navigation_center = target.center
	navigation_zoom = target.zoom
	save_navigation()
	if host.world != null:
		var state := String(host.world.fx_cfg.behavior["rest_state"])
		host.world.fx_cfg.set_option("state." + state, "camera.zoom", 1.0)
		host.world.fx_last_key = -1e6
		host.world._settle_camera_at_rest()
	refresh()


## Enough surrounding space to drag a full window beyond any main-area edge.
## Include existing stashes so Overview remains a way to retrieve every window.
func overview_region() -> Rect2:
	var region := Rect2(-canvas_size() * 1.25, canvas_size() * 3.5)
	for rect in pane_rects.values():
		region = region.merge(rect.grow(80))
	return region


## Visible workspace bounds in layout coordinates, not the Main-area frame.
func visible_canvas_rect() -> Rect2:
	var visible := viewport_content_rect()
	var bounds := Rect2(canvas_point_at(visible.position), Vector2.ZERO)
	for corner in [visible.end, Vector2(visible.position.x, visible.end.y), Vector2(visible.end.x, visible.position.y)]:
		bounds = bounds.expand(canvas_point_at(corner))
	return bounds


## -1..1 pressure per axis while a dragged window's pointer rests in a band at
## the view's edge; zero elsewhere, including over the tab bar.
func edge_pan_push() -> Vector2:
	return edge_pan_pressure(ScreenSpace.into(self, pointer_screen), viewport_content_rect())


## Only the cursor matters, never how much of a pane extends offscreen.
static func edge_pan_pressure(cursor: Vector2, visible: Rect2) -> Vector2:
	if not visible.has_point(cursor):
		return Vector2.ZERO
	return Vector2(
		_edge_push(cursor.x - visible.position.x, visible.end.x - cursor.x),
		_edge_push(cursor.y - visible.position.y, visible.end.y - cursor.y),
	).limit_length()


## Cumulative screen travel at full pressure. Integrating the smoothstep speed
## ramp makes both acceleration and distance independent of the frame rate.
static func edge_pan_travel(held: float) -> float:
	var elapsed := maxf(held - EDGE_PAN_DELAY, 0.0)
	var t := minf(elapsed / EDGE_PAN_RAMP, 1.0)
	return EDGE_PAN_MAX_SPEED * (
		EDGE_PAN_RAMP * (t * t * t - .5 * t * t * t * t)
		+ maxf(elapsed - EDGE_PAN_RAMP, 0.0)
	)


## Follow a dragged window without zooming. Overview is only a fit command,
## not a placement boundary: stop only when the pane reaches the layout limit.
func edge_pan(key: String, pixels: Vector2) -> bool:
	if not pane_rects.has(key): return false
	var local := ScreenSpace.into(self, pointer_screen)
	var shift := canvas_point_at(local + pixels) - canvas_point_at(local)
	var rect: Rect2 = pane_rects[key]
	shift = Layout.clamp_window_position(Rect2(rect.position + shift, rect.size)).position - rect.position
	if shift.length() < .01:
		return false
	begin_navigation_render()
	_fit_return = { }
	_cancel_main_magnet()
	_begin_navigation()
	navigation_center += shift
	_apply_navigation()
	return true


## Smoothly rise from zero at the band's inner boundary to full edge speed.
static func _edge_push(before: float, after: float) -> float:
	return smoothstep(0.0, EDGE_PAN_BAND, before) - smoothstep(0.0, EDGE_PAN_BAND, after)


func finish_window_move(key: String, cancel := false) -> void:
	var drop_point: Vector2 = preview_plan.get("point", Vector2.INF)
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
	if group.is_empty():
		moving = ""
		return
	if not cancel:
		var rect: Rect2 = Layout.find(group.tree, key).get("rect", pane_rects.get(key, Rect2()))
		if not preview_plan.is_empty() and key in preview_plan.incoming:
			group.tree.assign(preview_plan.tree)
		else:
			Layout.place(group.tree, key, rect, content_rect())
	clear_layout_preview()
	moving = ""
	refresh()
	if not cancel:
		host.session_backend.move_pane(host, key, drop_point)


func is_overview() -> bool:
	return (
		overview or (host.world != null and host.world.fx_cam_zoom * host.world.gesture_zoom < 0.95)
	)


func preview_window_move(
	key: String,
	rect: Rect2,
	point: Vector2,
	incoming: Dictionary = { },
	placements: Dictionary = {},
) -> Dictionary:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.is_empty() or (not group.tree.get("tiling", false) and incoming.is_empty()):
		clear_layout_preview()
		return { }
	if incoming.is_empty():
		incoming = Layout.find(group.tree, key)
	preview_plan = Layout.preview_placement(group.tree, incoming, rect, content_rect(), point, placements)
	# A local drag already carries its pane. A transfer needs a visible outline
	# even when the destination is floating or outside the Main Area.
	layout_preview.present(preview_plan, content_rect(), point, key.is_empty())
	return preview_plan


func clear_layout_preview() -> void:
	preview_plan = { }
	layout_preview.hide()


func begin_navigation_render() -> void:
	# Reuse GPU allocations while input is arriving on touchscreens and desktops.
	navigation_render_until = Time.get_ticks_msec() + 160
	navigation_render_frame = Engine.get_process_frames()
	_navigation_render_timer.start()


func _finish_navigation_render() -> void:
	# A slow phone frame can exceed the quiet-time deadline while the next
	# input sample is already being processed. Keep that frame's allocation.
	if Engine.get_process_frames() <= navigation_render_frame + 1:
		_navigation_render_timer.start()
		return
	navigation_render_until = 0
	update_raster_region()
	for pane in panes.values():
		if pane.visible:
			pane._resize_terminal_preview()


func holding_navigation_render_targets() -> bool:
	return navigation_render_until > 0 and (Time.get_ticks_msec() < navigation_render_until or Engine.get_process_frames() <= navigation_render_frame + 1) and canvas.size.x > 1 and canvas.size.y > 1
