extends Panel
const DesktopText := preload("res://scenes/DesktopText.gd")
signal header_changed
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
const ViewportInput := preload("res://scenes/TerminalViewportInput.gd")
## Freely positioned window chrome on the workspace canvas. It draws its
## content flat: the world's single camera zooms, leans and blurs the whole
## canvas. Persistent sessions never get reparented.
const Icons := preload("res://scenes/PaneIcons.gd")
const PaneHeader := preload("res://scenes/PaneHeader.gd")
const DefaultHeader := preload("res://scenes/PaneHeader.tscn")
var host: Node
var key := ''
var header: PaneHeader
var progress := preload("res://scenes/PaneProgress.gd").new()
var title_menu := PopupMenu.new()
var chromium_context_menu: PopupMenu
var hyperlink_context_menu: PopupMenu
var _hyperlink_source: Control
var chromium_frozen_overlay: ColorRect
## Shown instead of a frozen page when the chromium stopped unexpectedly.
var chromium_failure: VBoxContainer
var chromium_paused_label: Label
var chromium_failure_heading: Label
var chromium_failure_reason: Label
var chromium_restart_button: Button
var chromium_reload_button: Button
var chromium_close_button: Button
var handle: Label
var body := Control.new()
var texture := TextureRect.new()
var chrome: Control
var find_bar: PanelContainer
var _title_source: Node
var _chromium_source: Node
var compact_header := false
var touch_header := false
var _pressed := false
var _press := Vector2.ZERO
var _dragging := false
var _start_rect := Rect2()
var drag_start_rectangles: Dictionary = {}
var _resize_edges := Vector2.ZERO
var _resizing := false
## The application drag (tab bars, other tabs and windows, desktop) owns this drag.
var _transfer := false
## Shift-drag: releasing over this window's own content detaches it as well.
var _detach := false
## Seconds the drag pointer has rested in the view's edge band.
var _edge_pan_held := 0.0
var _layout_extent := Vector2i.ZERO
var _layout_font := -1
var _layout_padding := Vector4(-1, -1, -1, -1)
var _layout_scale := 0.0
var _layout_held := false
var _layout_region := Rect2()
var _grid_sync_pending := false
var _content_kind := ""
## A Chromium page's own material (pane_content.gdshader). The frozen overlay
## uses it while the page cuts a hole for the world's video layer instead.
var _page_material: ShaderMaterial
var _hole_material: ShaderMaterial
## The world composites this page beneath the canvas; see set_video_layer().
var video_layer := false


func _init(header_scene: PackedScene = DefaultHeader) -> void:
	var instance := header_scene.instantiate() if header_scene != null else DefaultHeader.instantiate()
	if not instance is PaneHeader:
		push_warning("pane_header_scene must inherit PaneHeader.tscn; keeping default")
		instance.free()
		instance = DefaultHeader.instantiate()
	header = instance
	handle = header.title


func _ready() -> void:
	set_process(false)
	get_window().focus_exited.connect(_stop_edge_pan)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.085, 0.11, 0.85)
	style.border_color = Color('384151')
	style.set_border_width_all(1)
	# Hiding an outer tile border must not change its content geometry.
	style.set_content_margin_all(1.0)
	add_theme_stylebox_override('panel', style)
	# Content draws directly in the pane. Whatever can reach the rounded
	# corners (the terminal or page texture) cuts itself to them in its own
	# shader; see pane_corner_clip.gdshaderinc and _sync_corner_clip().
	var column := VBoxContainer.new()
	column.add_theme_constant_override('separation', 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var header_margin := MarginContainer.new()
	header_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_margin.add_theme_constant_override("margin_left", 10)
	header_margin.add_theme_constant_override("margin_right", 6)
	column.add_child(header_margin)
	touch_header = preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	if touch_header:
		# Keep the body reservation fixed; scale client chrome without resizing VT.
		header_margin.custom_minimum_size.y = 30
		add_child(header)
		header.position = Vector2(10, 0)
	else:
		header_margin.add_child(header)
	header.configure(host.is_terminal_pane(key))
	header.title_input.connect(_handle_input)
	header.action_requested.connect(_header_action)
	handle.resized.connect(_refresh_title)
	# Popups belong to the OS window, not the projected/embedded pane viewport.
	# App-drawn menus can show the destructive close action in red.
	title_menu.prefer_native_menu = false
	title_menu.about_to_popup.connect(_update_title_menu_hints)
	_update_title_menu_hints()
	title_menu.id_pressed.connect(_title_menu_action.call_deferred)
	host.add_child(title_menu)
	tree_exiting.connect(func():
		if not host.moving_window and is_instance_valid(title_menu): title_menu.queue_free()
	)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.clip_contents = true
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(body)
	texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.stretch_mode = TextureRect.STRETCH_SCALE
	texture.gui_input.connect(_content_input)
	texture.mouse_entered.connect(_content_pointer_entered)
	texture.mouse_exited.connect(_content_pointer_exited)
	texture.focus_exited.connect(_release_chromium_input)
	body.add_child(texture)
	# Corner masks follow the pane's size and the content's place in it.
	item_rect_changed.connect(_sync_corner_clip)
	body.item_rect_changed.connect(_sync_corner_clip)
	texture.item_rect_changed.connect(_sync_corner_clip)
	body.add_child(progress)
	progress.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	progress.offset_bottom = 3
	_ensure_content_kind()
	tree_exiting.connect(func():
		if host.moving_window: return
		if is_instance_valid(chromium_context_menu): chromium_context_menu.queue_free()
		if is_instance_valid(hyperlink_context_menu): hyperlink_context_menu.queue_free())
	body.resized.connect(_resize_terminal_preview)
	refresh()


func _resize_chromium_preview() -> void:
	if not visible or not host.presentation_active: return
	var chromium: Node = host.chromiums.get(int(key.substr(1)))
	if chromium != null and texture.size.x >= 64 and texture.size.y >= 64:
		chromium.set_preview_size(texture.size)


func terminal_content_padding(configured: Vector4) -> Vector4:
	if host != null and host.is_terminal_pane(key):
		var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
		if not pair.is_empty() and pair.term.has_meta("server_content_insets"):
			var inset: Array = pair.term.get_meta("server_content_insets")
			var pad: float = pair.term.cell_padding
			return Vector4(inset[0] - pad, inset[1] - (size.y - body.size.y) - pad,
				inset[2] - (size.x - body.size.x) - pad, inset[3] - pad)
	# Top padding is the visible gap below title text. Font descent and spare row
	# height already contribute to that gap; do not add them a second time.
	#
	# Keep horizontal and bottom padding exactly as configured.
	var font := handle.get_theme_font("font")
	var font_size := handle.get_theme_font_size("font_size")
	var below_title := font.get_descent(font_size)
	# The title is bottom-aligned, so there is no extra centering offset.
	var result := configured
	result.y = maxf(0.0, configured.y - below_title)
	return result


## Layout metadata can arrive before its terminal/chromium model. Complete
## content setup once its type is known, including panes already in the tree.
func _ensure_content_kind() -> void:
	var kind := "terminal" if host.is_terminal_pane(key) else ("chromium" if host.is_chromium_pane(key) else "")
	if kind.is_empty() or kind == _content_kind: return
	_content_kind = kind
	header.configure(kind == "terminal")
	_update_title_menu_hints()
	if host.is_terminal_pane(key):
		texture.mouse_default_cursor_shape = Control.CURSOR_IBEAM
		# Linear premultiplied coverage, composited once into the linear canvas.
		texture.material = ShaderMaterial.new()
		texture.material.shader = preload('res://scenes/terminal_composite.gdshader')
	if host.is_chromium_pane(key):
		# Fit frames uniformly while Chromium reflows to the pane's new size.
		# Old frames must not stretch during the asynchronous resize.
		texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture.resized.connect(_resize_chromium_preview)
		_page_material = ShaderMaterial.new()
		_page_material.shader = preload('res://scenes/pane_content.gdshader')
		texture.material = _page_material
		chrome = preload('res://scenes/ChromiumChrome.gd').new()
		body.add_child(chrome)
		chrome.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		chrome.close_session_requested.connect(_confirm_chromium_close)
		texture.offset_top = 84
		chromium_frozen_overlay = ColorRect.new()
		chromium_frozen_overlay.name = "FrozenChromiumOverlay"
		chromium_frozen_overlay.color = Color(0.5, 0.5, 0.5, 0.45)
		chromium_frozen_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chromium_frozen_overlay.hide()
		# Covers the page exactly, so the page's corner mask applies as is.
		chromium_frozen_overlay.use_parent_material = true
		texture.add_child(chromium_frozen_overlay)
		chromium_frozen_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		chromium_paused_label = Label.new()
		chromium_paused_label.name = "PausedChromiumLabel"
		chromium_paused_label.text = "Paused"
		chromium_paused_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chromium_paused_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chromium_paused_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chromium_paused_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
		chromium_paused_label.add_theme_constant_override("outline_size", 6)
		chromium_paused_label.hide()
		chromium_frozen_overlay.add_child(chromium_paused_label)
		chromium_paused_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_build_chromium_failure()
		# Above the page, where Chrome shows its find bar.
		find_bar = preload("res://scenes/ChromiumFindBar.gd").new()
		body.add_child(find_bar)
		find_bar.closed.connect(_find_closed)
		find_bar.field.focus_entered.connect(func(): if host.pane_focus != key: host.focus_pane(key))
		find_bar.resized.connect(_place_find_bar)
		body.resized.connect(_place_find_bar)
		chrome.find_requested.connect(_find_requested)
	_sync_corner_clip()


func _find_requested(direction: int) -> void:
	var chromium: Node = host.chromiums.get(int(key.substr(1)))
	if chromium == null or not chromium.chromium_ready: return
	find_bar.session = chromium
	if direction == 0: find_bar.open()
	else: find_bar.step(direction < 0)
	_place_find_bar()


func _place_find_bar() -> void:
	if find_bar != null: find_bar.place(body.size, texture.offset_top)


## Closing the find bar returns the keyboard to the page, like Chrome.
func _find_closed() -> void:
	if host.pane_focus == key and texture.is_visible_in_tree():
		texture.focus_mode = Control.FOCUS_ALL
		texture.grab_focus()


## The texture's material cuts it to this pane's rounded rectangle.
func _sync_corner_clip() -> void:
	var radius := float((get_theme_stylebox("panel") as StyleBoxFlat).corner_radius_top_left)
	var offset := (get_global_transform().affine_inverse() * texture.get_global_transform()).origin
	for clip in [texture.material, _page_material, _hole_material]:
		if clip is ShaderMaterial:
			RenderUpdates.uniform(clip, "pane_size", size)
			RenderUpdates.uniform(clip, "pane_radius", radius)
			RenderUpdates.uniform(clip, "pane_offset", offset)


## In a world with a video layer, the world draws the page beneath the canvas
## and the pane erases the canvas where the page would be.
##
## A new page frame then redraws the world without the canvas. Returns whether
## it changed.
func set_video_layer(enabled: bool) -> bool:
	if enabled == video_layer or _page_material == null: return false
	video_layer = enabled
	if is_instance_valid(_chromium_source): _chromium_source.present_at_draw = enabled
	if enabled and _hole_material == null:
		_hole_material = ShaderMaterial.new()
		_hole_material.shader = preload("res://scenes/pane_video_hole.gdshader")
	texture.material = _hole_material if enabled else _page_material
	# The overlay covers the page exactly, so the page's corner mask fits it.
	chromium_frozen_overlay.use_parent_material = not enabled
	chromium_frozen_overlay.material = _page_material if enabled else null
	_sync_corner_clip()
	return true


## Where the world draws this page and its pane, in the canvas texels that
## `texels` maps the canvas's 2D coordinates to. Empty unless the canvas would
## draw the page as an opaque, unrotated rectangle.
func video_layer_geometry(texels: Transform2D) -> Dictionary:
	if _page_material == null: return {}
	var page := texture.texture
	if page == null or not texture.is_visible_in_tree():
		return {}
	var source := Vector2i(page.get_size())
	var page_texels := texels * texture.get_global_transform_with_canvas()
	if (source.x < 1 or source.y < 1 or not is_zero_approx(page_texels.x.y) or not is_zero_approx(page_texels.y.x)
			or page_texels.x.x <= 0.0 or page_texels.y.y <= 0.0):
		return {}
	var item: Node = texture
	while item is CanvasItem:
		if item.modulate != Color.WHITE or (item == texture and item.self_modulate != Color.WHITE): return {}
		item = item.get_parent()
	var rect := page_texels * keep_aspect_centered(texture.size, source)
	# The sheet filters the hole's edges across a texel on either side.
	if rect.size.x < 2.0 or rect.size.y < 2.0: return {}
	var pane_texels := texels * get_global_transform_with_canvas()
	var radius := float((get_theme_stylebox("panel") as StyleBoxFlat).corner_radius_top_left)
	return {
		"texture": page,
		"rect": rect,
		"clip": pane_texels * Rect2(Vector2.ZERO, size),
		"radius": radius * (pane_texels.x.x + pane_texels.y.y) * 0.5,
	}


## Where TextureRect.STRETCH_KEEP_ASPECT_CENTERED draws `source` in `area`,
## including its integer sizes.
static func keep_aspect_centered(area: Vector2, source: Vector2i) -> Rect2:
	var width := int(source.x * area.y / source.y)
	var height := int(area.y)
	if width > area.x:
		width = int(area.x)
		height = source.y * width / source.x
	return Rect2((area - Vector2(width, height)) / 2.0, Vector2(width, height))


func _chromium_presented() -> void:
	# Pages drawn in the canvas need it redrawn for each new frame.
	if not video_layer and is_visible_in_tree():
		RenderUpdates.prepare(get_viewport() as SubViewport)


## Keep a viewport-sized crop while navigating, rather than stretching a tiny
## visible slice into a cached texture.
##
## Clamp its origin at pane edges; large panes still render only a bounded
## window, not their full contents.
static func navigation_raster_region(view: Rect2, full: Rect2, previous := Rect2()) -> Rect2:
	if not view.intersects(full): return Rect2()
	var extent := view.size.max(previous.size).min(full.size)
	return Rect2(view.position.clamp(full.position, full.end - extent), extent)


func _resize_terminal_preview() -> void:
	if not visible or not host.presentation_active: return
	_ensure_content_kind()
	if not host.is_terminal_pane(key) or host.world == null:
		return
	var id := int(key.substr(1))
	# A landscape IME can leave one valid terminal row. Retain its new crop
	# and control geometry instead of keeping the previous tall viewport.
	if not host.sessions.has(id) or body.size.x < 32 or body.size.y < 1:
		return
	var pair: Dictionary = host.sessions[id]
	if not pair.vp.is_connected("render_budget_changed", _resize_terminal_preview):
		pair.vp.connect("render_budget_changed", _resize_terminal_preview, CONNECT_DEFERRED)
	var extent := Vector2i(body.size.round())
	var font_size: int = int(pair.term.get_meta("pane_font_size", host.world.term_font_size))
	var padding := terminal_content_padding(host.world.terminal_window.padding)
	if pair.term.get_live_font_size() != font_size:
		pair.term.set_live_font_size(font_size)
	if not _grid_sync_pending:
		_grid_sync_pending = true
		_sync_terminal_grid.call_deferred()
	# The same texel density as the canvas, so zoomed text stays sharp.
	var pane_scale: float = self.scale.x
	var scale: float = ceilf(maxf(host.workspace_view.canvas_scale() * pane_scale, 1.0) * 2.0) / 2.0
	var full := Rect2(Vector2.ZERO, Vector2(extent))
	var origin: Vector2 = host.workspace_view.terminal_origin(key)
	# The texture can be supersampled or budget-limited. Snap the grid to the
	# presenting window, independently of that intermediate texture density.
	var window_scale := get_window().content_scale_factor
	if DisplayServer.get_name() in ["Windows", "Wayland", "X11"] and pair.term.has_method("set_pixel_grid"):
		var density := 0.0
		if not is_equal_approx(window_scale, roundf(window_scale)): density = window_scale * pane_scale
		var grid_origin := origin + Vector2(padding.x, padding.y) * pane_scale
		pair.term.set_pixel_grid(density, grid_origin * window_scale if density > 0.0 else Vector2.ZERO)
	var region: Rect2 = host.workspace_view.raster_region
	region.position = (region.position - origin) / pane_scale
	region.size /= pane_scale
	var hold_targets: bool = host.workspace_view.holding_navigation_render_targets()
	if pair.vp.get_meta("terminal_capture_active", false) or preload("res://scenes/TerminalViewportUpdates.gd").is_transition_live(pair.vp):
		# Both frozen captures and live arrivals need the destination's complete
		# geometry, even when it is outside the travelling camera's current crop.
		#
		# Otherwise the no-area return below leaves the terminal at its old size.
		# The normal pixel budget still bounds allocation.
		region = full
	elif hold_targets:
		var previous := _layout_region if _layout_held and extent == _layout_extent else Rect2()
		region = navigation_raster_region(region, full, previous)
	else:
		region = region.intersection(full)
	if not region.has_area():
		_layout_held = false
		preload("res://scenes/TerminalViewportUpdates.gd").set_visible(pair.vp, false)
		return
	preload("res://scenes/TerminalViewportUpdates.gd").set_visible(pair.vp, true)
	# Reuse density, not just pixel dimensions. A changed crop must never be
	# squeezed into the old allocation with different X/Y sampling scales.
	if hold_targets and _layout_held and _layout_scale > 0.0: scale = _layout_scale
	scale = minf(scale, 8192.0 / maxf(region.size.x, region.size.y))
	var pixel_budget: float = pair.vp.get_meta("terminal_pixel_budget", 4_000_000)
	scale = minf(scale, sqrt(pixel_budget / maxf(region.get_area(), 1.0)))
	var raster := Vector2i((region.size * scale).floor()).max(Vector2i.ONE)
	if pair.term.has_method('set_raster_scale'):
		pair.term.set_raster_scale(ceilf(scale * 2.0) / 2.0)
	# Focus, title and monitor updates must never touch terminal geometry.
	if (
		extent == _layout_extent and font_size == _layout_font and padding == _layout_padding
		and scale == _layout_scale and region == _layout_region and hold_targets == _layout_held
		and pair.vp.size == raster
	):
		return
	_layout_extent = extent
	_layout_font = font_size
	_layout_padding = padding
	_layout_scale = scale
	_layout_held = hold_targets
	_layout_region = region
	if pair.term.get_live_font_size() != font_size:
		pair.term.set_live_font_size(font_size)
	pair.vp.size_2d_override = extent
	pair.vp.size_2d_override_stretch = true
	if pair.vp.size != raster:
		pair.vp.size = raster
	pair.vp.oversampling = true
	var crop_scale: Vector2 = Vector2(extent) / region.size
	pair.vp.canvas_transform = Transform2D(
		Vector2(crop_scale.x, 0),
		Vector2(0, crop_scale.y),
		-region.position * crop_scale,
	)
	RenderUpdates.uniform(texture.material,
		'texture_region',
		Vector4(
			region.position.x / extent.x,
			region.position.y / extent.y,
			region.size.x / extent.x,
			region.size.y / extent.y,
		),
	)
	pair.term.position = Vector2(padding.x, padding.y)
	pair.term.size = (Vector2(extent) - Vector2(padding.x + padding.z, padding.y + padding.w)).max(Vector2.ONE)
	# A crop transform changes pixels even when the PTY and target size stay still.
	preload("res://scenes/TerminalViewportUpdates.gd").request(pair.vp)


func _sync_terminal_grid() -> void:
	_grid_sync_pending = false
	if is_instance_valid(host) and host.session_backend != null and host.sessions.has(int(key.substr(1))):
		host.session_backend.sync_pane_grid(host, key)


var _title_layout_cache: Dictionary = {}


## Header geometry in pane coordinates, independent of transient pane zoom.
func title_handle_rect() -> Rect2:
	var transform := Transform2D.IDENTITY
	var node: CanvasItem = handle
	while node != self:
		transform = node.get_transform() * transform
		node = node.get_parent() as CanvasItem
	return transform * Rect2(Vector2.ZERO, handle.size)


## Always format from the original title at the destination label's width.
func title_for_label(label: Label) -> String:
	if host == null or not host.is_terminal_pane(key):
		return handle.text
	var title := _original_title()
	var signature := [title, label.size.x, label.get_theme_font("font"), label.get_theme_font_size("font_size"), label.get_theme_stylebox("normal").get_minimum_size()]
	var slot := label.get_instance_id()
	if _title_layout_cache.has(slot) and _title_layout_cache[slot].signature == signature:
		return _title_layout_cache[slot].text
	var colon := title.find(":")
	if colon >= 0 and "@" in title.left(colon):
		var suffix := title.substr(colon + 1)
		if suffix.begins_with("/") or suffix.begins_with("~"):
			title = suffix
	var full := title
	if title.begins_with("/") or title.begins_with("~"):
		var font := label.get_theme_font("font")
		var font_size := label.get_theme_font_size("font_size")
		var budget := maxf(0, label.size.x - label.get_theme_stylebox("normal").get_minimum_size().x)
		while title.length() > 1 and font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > budget:
			title = title.substr(1)
			full = "…" + title
	_title_layout_cache[slot] = {"signature": signature, "text": full}
	return full


func _original_title() -> String:
	return host.pane_title(key)


func _bind_title_source() -> void:
	var source: Node = host.session_model(int(key.substr(1)))
	if _title_source != source:
		if is_instance_valid(_title_source):
			_title_source.title_changed.disconnect(_on_title_changed)
			_title_source.progress_changed.disconnect(_refresh_progress)
		_title_source = source
		if is_instance_valid(_title_source):
			_title_source.title_changed.connect(_on_title_changed)
			_title_source.progress_changed.connect(_refresh_progress)
	if is_instance_valid(_title_source):
		_refresh_progress(_title_source.progress_state, _title_source.progress_value)
	else: _refresh_progress(0, -1)


func _refresh_progress(state: int, value: int) -> void:
	if not visible or not host.presentation_active: return
	progress.set_progress(state, value)


func _on_title_changed(_title: String) -> void:
	# Metadata changes never enter the terminal sizing or viewport path.
	_refresh_title()


func _exit_tree() -> void:
	_bind_hyperlink_source(null)
	if is_instance_valid(_title_source):
		_title_source.title_changed.disconnect(_on_title_changed)
		_title_source.progress_changed.disconnect(_refresh_progress)
	_title_source = null
	if is_instance_valid(_chromium_source):
		_chromium_source.changed.disconnect(_refresh_chromium_content)
		_chromium_source.presented.disconnect(_chromium_presented)
		_chromium_source.present_at_draw = false
		if is_instance_valid(chromium_context_menu) and _chromium_source.context_menu_requested.is_connected(chromium_context_menu.display):
			_chromium_source.context_menu_requested.disconnect(chromium_context_menu.display)
	_chromium_source = null


func _bind_hyperlink_source(source: Control) -> void:
	if _hyperlink_source == source: return
	if is_instance_valid(_hyperlink_source):
		_hyperlink_source.hyperlink_context_menu_requested.disconnect(_show_hyperlink_menu)
	if is_instance_valid(hyperlink_context_menu): preload("res://scenes/PopupChrome.gd").close(hyperlink_context_menu)
	_hyperlink_source = source
	if is_instance_valid(source):
		source.hyperlink_context_menu_requested.connect(_show_hyperlink_menu)


func _show_hyperlink_menu(uri: String, openable: bool, web: bool) -> void:
	if not is_visible_in_tree() or not host.presentation_active: return
	if not is_instance_valid(hyperlink_context_menu):
		hyperlink_context_menu = preload("res://scenes/HyperlinkContextMenu.gd").new()
		host.add_child(hyperlink_context_menu)
		# Explicit browser actions always run on the client, even for a remote PTY.
		hyperlink_context_menu.open_in_browser_requested.connect(OS.shell_open, CONNECT_DEFERRED)
		hyperlink_context_menu.show_in_chromium_requested.connect(_show_link_in_chromium, CONNECT_DEFERRED)
	hyperlink_context_menu.display(uri, openable, web, host.workspace_view.pointer_screen)


func _show_link_in_chromium(uri: String) -> void:
	# The server's Chromium API uses lowercase schemes; preserve path casing.
	var colon := uri.find(":")
	var url := uri.left(colon).to_lower() + uri.substr(colon)
	host.create_chromium_session(url, int(key.substr(1)))


func _refresh_title() -> void:
	if host == null or not visible or not host.presentation_active or not host.is_terminal_pane(key):
		return
	var title := title_for_label(handle)
	if handle.text != title or not handle.tooltip_text.is_empty():
		handle.text = title
		handle.tooltip_text = ""
		header_changed.emit()


func refresh() -> void:
	if not visible or not host.presentation_active: return
	_ensure_content_kind()
	var session: Dictionary = host.sessions.get(int(key.substr(1)), {})
	header.set_filetree_open(not session.is_empty() and bool(session.term.get_meta("filetree_open", false)))
	if is_instance_valid(host.world):
		var radius: int = host.world.terminal_window.corner_radius
		var panel_style: StyleBoxFlat = get_theme_stylebox("panel")
		if panel_style.corner_radius_top_left != radius:
			panel_style.set_corner_radius_all(radius)
			_sync_corner_clip()
	var id := int(key.substr(1))
	if host.is_terminal_pane(key):
		_bind_title_source()
		_refresh_title()
		texture.visible = true
		_resize_terminal_preview()
		if host.sessions.has(id):
			var pair: Dictionary = host.sessions[id]
			_bind_hyperlink_source(pair.term)
			texture.texture = pair.vp.get_texture()
			# Layout may create the pane before its terminal mirror arrives.
			pair.term.show_hyperlink_tooltip = false
			texture.set_meta("terminal_control", pair.term)
	else:
		_refresh_chromium_content()
		_resize_chromium_preview()


## Every pane keeps its configured glass above the world's backdrop. Flat
## tiling hides only the outer frame; the gaps remain visibly behind the
## panes.
##
## Called after layout so edge decisions use the same bounds as the renderer.
func refresh_background(tree: Dictionary, tiled_area: Rect2) -> void:
	if not is_instance_valid(host.world) or host.world.terminal_config == null:
		return
	var world: Node = host.world
	var item: Dictionary = host.workspace_layout.find(tree, key)
	var hide_outer_border: bool = (
		tree.get("tiling", false)
		and not item.get("stashed", false)
		and not item.get("graph_floating", false)
		and host.workspace_view.moving != key
		and world.has_method("uses_workspace_backdrop")
		and world.uses_workspace_backdrop()
	)
	var style: StyleBoxFlat = get_theme_stylebox("panel")
	var color: Color = world.terminal_config.background.color
	color.a = world.terminal_config.background.alpha
	if style.bg_color != color:
		style.bg_color = color
	var rect := Rect2(position, size)
	var edges := [
		is_equal_approx(rect.position.x, tiled_area.position.x),
		is_equal_approx(rect.position.y, tiled_area.position.y),
		is_equal_approx(rect.end.x, tiled_area.end.x),
		is_equal_approx(rect.end.y, tiled_area.end.y),
	]
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		var width := 0 if hide_outer_border and edges[side] else 1
		if style.get_border_width(side) != width:
			style.set_border_width(side, width)


func _refresh_chromium_content() -> void:
	# Hidden panes also release textures when their remote decoder is removed.
	if is_instance_valid(_chromium_source) and _chromium_source.texture == null:
		texture.texture = null
	if not visible or not host.presentation_active: return
	var chromium: Node = host.chromiums.get(int(key.substr(1)))
	if chromium == null: return
	# Canonical layout can create this pane before the chromium mirror arrives.
	# Bind once the mirror exists, and rebind after a replaced connection model.
	if _chromium_source != chromium:
		if is_instance_valid(_chromium_source):
			_chromium_source.changed.disconnect(_refresh_chromium_content)
			_chromium_source.presented.disconnect(_chromium_presented)
			_chromium_source.present_at_draw = false
			if is_instance_valid(chromium_context_menu):
				_chromium_source.context_menu_requested.disconnect(chromium_context_menu.display)
		_chromium_source = chromium
		chromium.changed.connect(_refresh_chromium_content)
		chromium.presented.connect(_chromium_presented)
		chromium.present_at_draw = video_layer
		if not is_instance_valid(chromium_context_menu):
			chromium_context_menu = preload("res://scenes/ChromiumContextMenu.gd").new()
			host.add_child(chromium_context_menu)
		chromium_context_menu.chromium = chromium
		chromium.context_menu_requested.connect(chromium_context_menu.display)
	if handle.text != chromium.title:
		handle.text = chromium.title
		header_changed.emit()
	texture.texture = chromium.texture if chromium.captured_page_id == chromium.selected_page_id else null
	if chromium_frozen_overlay != null:
		# A paused pane is off-screen or projected too small to read: gray it
		# out over its last picture rather than streaming frames nobody sees.
		chromium_frozen_overlay.visible = chromium.native_visible or chromium.stream_paused
		chromium_paused_label.visible = chromium.stream_paused and not chromium.native_visible
		if chromium_paused_label.visible:
			# Sized with the page, so it stays legible as the camera zooms in.
			chromium_paused_label.add_theme_font_size_override("font_size", int(clampf(texture.size.y / 8.0, 22.0, 160.0)))
	if chromium_failure != null:
		# A stopped browser can be relaunched; a crashed or stuck page reloaded.
		var stopped: bool = not chromium.failure_reason.is_empty()
		var stuck: bool = chromium.page_not_responding and not chromium.page_crashed
		chromium_failure.visible = stopped or chromium.page_crashed or stuck
		chromium_failure_heading.text = ("Chromium stopped unexpectedly" if stopped
			else ("This page is not responding" if stuck else "This page crashed"))
		chromium_failure_reason.text = (chromium.failure_reason if stopped
			else tr("It is stuck running a script. Reload starts it again.") if stuck
			else tr("Its renderer stopped. Reload starts a new one."))
		chromium_restart_button.visible = stopped and chromium.restartable
		chromium_restart_button.disabled = chromium.restarting
		chromium_reload_button.visible = not stopped and (chromium.page_crashed or stuck)
		chromium_close_button.visible = stopped
	if chrome != null:
		chrome.refresh(chromium)
	if find_bar != null:
		find_bar.session = chromium
		find_bar.refresh()


func _header_action(action: StringName) -> void:
	match action:
		&"filetree":
			host.focus_pane(key)
			host.prefix_commands.filetree.toggle(host, true)
		&"chromium": host.create_chromium_session("", int(key.substr(1)), true)
		&"split_right": host.workspace_view.split_window("h", key)
		&"split_down": host.workspace_view.split_window("v", key)
		&"close": _close_pane()


func _close_pane() -> void:
	if host.is_terminal_pane(key):
		host.request_close_terminal(int(key.substr(1)))
	else:
		_confirm_chromium_close()


func _toggle_resource_monitor() -> void:
	var hide: bool = host.pane_status_visible and host.pane_focus == key
	host.focus_pane(key)
	if host.pane_status_visible == hide:
		host.toggle_pane_status()


func set_title_content_cut(height: float, feather := 0.0) -> void:
	if host.is_terminal_pane(key) and texture.material is ShaderMaterial:
		# Dim ink under the translucent title. Neither the PTY grid nor pane changes.
		RenderUpdates.uniform(texture.material, "content_clip_top", clampf(height / maxf(body.size.y, 1.0), 0.0, 1.0))
		RenderUpdates.uniform(texture.material, "content_clip_feather", feather / maxf(body.size.y, 1.0))


func secondary_split_at(point: Vector2) -> bool:
	if compact_header or not host.is_terminal_pane(key): return false
	var action := header.action_at(point)
	if action in ["split_right", "split_down"]:
		host.workspace_view.split_window("h" if action == "split_right" else "v", key, true)
		return true
	return false


func set_title_inset(inset: float) -> void:
	if not host.is_terminal_pane(key):
		return
	# Titles dim the top of a fixed terminal surface. Never translate or shrink
	# its contents: bottom status lines must remain inside the pane at any zoom.
	texture.offset_top = 0.0
	texture.offset_bottom = 0.0
	set_title_content_cut(inset)
	progress.offset_top = maxf(inset, 0)
	progress.offset_bottom = progress.offset_top + 3


func set_compact_header(value: bool, title_height := 0.0) -> void:
	compact_header = value
	header.set_compact(value, value and host.pane_focus == key and 24.0 * header.scale.y >= title_height * 0.1)

func begin_header_drag(sheet_point: Vector2, detach := false) -> void:
	_pressed = true
	_press = sheet_point
	_start_rect = layout_rect()
	drag_start_rectangles = host.workspace_view.pane_rects.duplicate(true)
	_detach = detach
	_transfer = false
	_edge_pan_held = 0.0
	host.workspace_view.wake_pane_physics()
	host.focus_pane(key)


func _title_menu_action(id: int) -> void:
	match id:
		5: host.rename_pane(key)
		6: _header_action(&"filetree")
		7: host.workspace_view.resize_to_fit_main(key)
		1: _toggle_resource_monitor()
		2: host.create_chromium_session("", int(key.substr(1)), true)
		3: host.workspace_view.split_window("h", key)
		4: host.workspace_view.split_window("v", key)
		8: host.workspace_view.split_window("h", key, true)
		9: host.workspace_view.split_window("v", key, true)
		0: _close_pane()


func _update_title_menu_hints() -> void:
	# One ordered definition for initial creation, late pane metadata, and popup
	# refresh. Never append new actions after the destructive final group.
	title_menu.clear()
	_title_menu_item(5, "Rename Pane…", "RenamePane")
	_title_menu_item(7, "Resize to fit main view", "ResizeToFitMain")
	title_menu.add_separator()
	if host.is_terminal_pane(key):
		# Arrows mark the side the new pane takes; the header keeps plain icons.
		var view = host.workspace_view
		_title_menu_item(8, "New Pane Left", "NewPaneLeft", view.split_direction_icon("left"))
		_title_menu_item(3, "New Pane Right", "NewPaneRight", view.split_direction_icon("right"))
		_title_menu_item(9, "New Pane Above", "NewPaneAbove", view.split_direction_icon("up"))
		_title_menu_item(4, "New Pane Below", "NewPaneBelow", view.split_direction_icon("down"))
		title_menu.add_separator()
		_title_menu_item(6, "Open filetree", "ToggleFiletree", Icons.filetree())
		_title_menu_item(2, "Open Chromium", "NewChromium", Icons.chromium())
	_title_menu_item(1, "Pane status", "PaneStatus", Icons.monitor())
	title_menu.add_separator()
	_title_menu_item(0, "Close pane", "ClosePane", Icons.trash())
	preload("res://scenes/PopupChrome.gd").mark_danger(title_menu, title_menu.get_item_index(0))


func _title_menu_item(id: int, source_text: String, action: String, icon: Texture2D = null) -> void:
	var label := tr(source_text)
	var hint: String = host.shortcut_text(action)
	if not hint.is_empty(): label = "%s (%s)" % [label, hint]
	if icon == null: title_menu.add_item(label, id)
	else: title_menu.add_icon_item(Icons.menu_icon(title_menu, icon), label, id)
	# The host owns shortcut dispatch; this menu only displays current bindings.
	title_menu.set_item_shortcut_disabled(title_menu.get_item_index(id), true)


func show_title_menu() -> void:
	host.focus_pane(key)
	preload("res://scenes/input/PointerPopup.gd").open(title_menu)


func _handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.double_click:
			_cancel_drag()
			host.workspace_view._held = 0
			host.workspace_view.toggle_fit_pane(key)
		else:
			begin_header_drag(handle.get_global_transform() * event.position, event.shift_pressed)
		handle.accept_event()


## Cancel a gesture transaction before a pinch, focus loss, or touch cancellation.
func abort_drag() -> void:
	if not (_pressed or _resizing): return
	var was_resizing := _resizing
	if _transfer:
		host.application.cancel_drag()
	elif _dragging or _resizing:
		host.workspace_view.set_window_rect(key, _start_rect, _resizing)
		host.workspace_view.finish_window_move(key, true)
	if _resizing: host.workspace_view.agent_links.tools.before = {}
	_cancel_drag()
	# An unrelated commit may have reached the owner mid-resize. Publish the
	# restored rectangle as the newest edit, as tile-divider cancellation does.
	if was_resizing: host.session_backend.move_pane(host, key, Vector2.INF)


func _cancel_drag() -> void:
	var view: Control = host.workspace_view
	var was_moving: bool = view.moving == key
	view.clear_layout_preview()
	view.moving = ""
	_pressed = false
	_dragging = false
	_resizing = false
	_transfer = false
	_stop_edge_pan()
	# Transfer cancellation can finish without another layout pass. Restore a
	# tiled pane's outer border after releasing its temporary floating frame.
	if was_moving:
		var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
		if not group.is_empty():
			refresh_background(group.tree, host.workspace_layout.tiling_area(group.tree, view.content_rect()))
	view.wake_pane_physics()


## This window's rectangle in the workspace layout: the view's coordinates at rest.
func layout_rect() -> Rect2:
	var view: Control = host.workspace_view
	return view.pane_rects.get(key, Rect2(position, size))


## Offset from the window's top-left corner to the point grabbed on its header.
func grab_offset() -> Vector2:
	var view: Control = host.workspace_view
	return _press - view.canvas_root.get_global_transform() * _start_rect.position


func _drag_to(screen: Vector2, delta: Vector2) -> void:
	var app: Node = host.application
	# Over its own tab's content the window simply moves. Tab bars, other tabs
	# (opened by hovering), sessions panels, other windows and the desktop are transfers.
	var local: bool = not _detach and app._window_at(screen) == host \
			and host.workspace_layout.active == host.workspace_layout.containing(key) \
			and not app._within_bar(host, screen) \
			and preload("res://scenes/session/SessionPanelDrag.gd").hit(app, screen, host).is_empty()
	if local:
		if _transfer:
			app.release_pane_drag()
		_transfer = false
		set_process(true)
		var view: Control = host.workspace_view
		# Navigation may expose any side of Main, but never hide the drag handle
		# under the chrome or past the visible viewport's edge.
		var rect: Rect2 = view.reachable_rect(key, Rect2(_start_rect.position + delta, _start_rect.size), view.visible_canvas_rect())
		view.set_window_rect(key, host.workspace_layout.clamp_window_position(rect))
		host.workspace_view.preview_window_move(
			key,
			layout_rect(),
			host.workspace_view.layout_point(screen),
		)
		return
	_stop_edge_pan()
	host.workspace_view.clear_layout_preview()
	if not _transfer:
		_transfer = true
		host.workspace_view.set_window_rect(key, _start_rect)
		app.begin_pane_drag(host, self, key, _detach)
	app.update_drag(screen)


## Invisible finger targets: 44 screen pixels across an edge, mostly outside
## the pane. Keep the content interior available for scrolling and selection.
static func touch_resize_edges(point: Vector2, extent: Vector2, units: Vector2) -> Vector2:
	var outside := units * 36.0
	if not Rect2(-outside, extent + outside * 2.0).has_point(point):
		return Vector2.ZERO
	var inside := (units * 8.0).min(extent * .2)
	var corner := (units * 22.0).min(extent * .25)
	var side := Vector2(-1 if point.x < extent.x * .5 else 1, -1 if point.y < extent.y * .5 else 1)
	var distance := Vector2(point.x if side.x < 0 else extent.x - point.x, point.y if side.y < 0 else extent.y - point.y)
	if distance.x <= corner.x and distance.y <= corner.y:
		return side
	return Vector2(side.x if distance.x <= inside.x else 0, side.y if distance.y <= inside.y else 0)


func _edge_at(point: Vector2, touch := false) -> Vector2:
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
	var tree: Dictionary = group.get("tree", { })
	if tree.get("tiling", false) and not host.workspace_layout.find(tree, key).get("stashed", false) and not host.workspace_layout.find(tree, key).get("graph_floating", false):
		return Vector2.ZERO
	if touch:
		# Readable headers can put their last action close to a screen-space
		# corner. A real button always wins over the invisible resize target.
		var sheet_point := get_global_transform() * point
		if not header.action_at(sheet_point).is_empty():
			return Vector2.ZERO
		# Measure through the displayed camera, including pane scale/tilt, so
		# zooming out never makes a finger target smaller.
		var view: Control = host.workspace_view
		var transform := get_transform()
		var screen: Vector2 = view.window_point(transform * point)
		var pixels := Vector2(
			screen.distance_to(view.window_point(transform * (point + Vector2.RIGHT))),
			screen.distance_to(view.window_point(transform * (point + Vector2.DOWN))),
		)
		return touch_resize_edges(point, size, Vector2.ONE / pixels.max(Vector2(.001, .001)))
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return Vector2.ZERO
	if point.x > size.x - 16 and point.y > size.y - 16:
		return Vector2.ONE
	return Vector2(
		-1 if point.x < 7 else (1 if point.x > size.x - 7 else 0),
		-1 if point.y < 6 else (1 if point.y > size.y - 7 else 0),
	)


## The resize cursor for a canvas point on this window's edges, or -1.
func resize_cursor(point: Vector2) -> int:
	var edges := (
		_resize_edges
		if _resizing
		else _edge_at(get_global_transform().affine_inverse() * point)
	)
	if edges == Vector2.ZERO:
		return -1
	if edges.x == 0:
		return CURSOR_VSIZE
	if edges.y == 0:
		return CURSOR_HSIZE
	return CURSOR_FDIAGSIZE if edges.x == edges.y else CURSOR_BDIAGSIZE


func _resize_rect(delta: Vector2) -> Rect2:
	var rect := _start_rect
	if _resize_edges.x < 0:
		rect.position.x = minf(_start_rect.position.x + delta.x, _start_rect.end.x - 320)
		rect.size.x = _start_rect.end.x - rect.position.x
	elif _resize_edges.x > 0:
		rect.size.x = maxf(320, _start_rect.size.x + delta.x)
	if _resize_edges.y < 0:
		rect.position.y = minf(_start_rect.position.y + delta.y, _start_rect.end.y - 200)
		rect.size.y = _start_rect.end.y - rect.position.y
	elif _resize_edges.y > 0:
		rect.size.y = maxf(200, _start_rect.size.y + delta.y)
	return rect


func _release_chromium_input() -> void:
	if is_instance_valid(host.touch_keybar): host.touch_keybar.cancel_pointer(key)
	if host.is_chromium_pane(key):
		var chromium: Node = host.chromiums.get(int(key.substr(1)))
		if is_instance_valid(chromium) and chromium.has_method("release_input"):
			chromium.release_input()


func _content_pointer_entered() -> void:
	if not host.is_terminal_pane(key): return
	var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
	if not pair.is_empty(): ViewportInput.set_pointer_inside(pair.vp, true)


func _content_pointer_exited() -> void:
	if not host.is_terminal_pane(key): return
	var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
	if not pair.is_empty(): ViewportInput.set_pointer_inside(pair.vp, false)
	texture.mouse_default_cursor_shape = Control.CURSOR_IBEAM


func _content_input(event: InputEvent) -> void:
	if is_instance_valid(host.touch_keybar):
		host.touch_keybar.apply_pointer_modifiers(event, key)
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		host.focus_pane(key)
	if host.is_chromium_pane(key):
		var chromium: Node = host.chromiums.get(int(key.substr(1)))
		if chromium != null:
			texture.focus_mode = Control.FOCUS_ALL
			if event is InputEventMouseButton and event.pressed: texture.grab_focus()
			if event.has_meta("touch_travel"):
				# The canvas measured the finger's travel; the page needs it here.
				event.set_meta("touch_travel", texture.get_global_transform_with_canvas().affine_inverse().basis_xform(event.get_meta("touch_travel")))
			chromium.remote_input(event, texture.size)
			texture.accept_event()
			return
	else:
		var pair: Dictionary = host.sessions.get(int(key.substr(1)), { })
		# The terminal's layout is the body's size, so body pixels are its pixels.
		if not pair.is_empty() and (event is InputEventMouse or event is InputEventGesture):
			var forwarded: InputEvent = event.duplicate()
			forwarded.position = pair.vp.canvas_transform * event.position
			if event.has_meta("touch_travel"):
				# The canvas measured the finger's travel; the terminal moves its
				# rows exactly that far, so it needs it in its own pixels.
				var local: Vector2 = texture.get_global_transform_with_canvas().affine_inverse().basis_xform(event.get_meta("touch_travel"))
				forwarded.set_meta("touch_travel", pair.vp.canvas_transform.basis_xform(local))
			if forwarded is InputEventMouse:
				forwarded.global_position = forwarded.position
			if forwarded is InputEventMouseMotion:
				forwarded.relative = pair.vp.canvas_transform.basis_xform(event.relative)
			# Inactive panes reject keyboard/IME input, but the pointed-at pane
			# must still receive hover and scroll without changing keyboard focus.
			var disabled: bool = pair.vp.gui_disable_input
			if disabled: ViewportInput.set_disabled(pair.vp, false)
			ViewportInput.set_pointer_inside(pair.vp, true)
			pair.vp.push_input(forwarded, true)
			if pair.has("term"):
				texture.mouse_default_cursor_shape = pair.term.get_cursor_shape(event.position - pair.term.position)
			if disabled: ViewportInput.set_disabled(pair.vp, true)
	texture.accept_event()


func _build_chromium_failure() -> void:
	chromium_failure = VBoxContainer.new()
	chromium_failure.name = "ChromiumFailure"
	chromium_failure.alignment = BoxContainer.ALIGNMENT_CENTER
	chromium_failure.add_theme_constant_override("separation", 12)
	chromium_failure.hide()
	texture.add_child(chromium_failure)
	chromium_failure.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	chromium_failure_heading = Label.new()
	chromium_failure_heading.text = "Chromium stopped unexpectedly"
	chromium_failure_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chromium_failure_heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chromium_failure_heading.add_theme_font_size_override("font_size", DesktopText.size(22))
	chromium_failure.add_child(chromium_failure_heading)
	chromium_failure_reason = Label.new()
	# The owner's diagnostic is shown verbatim, never as a catalog message.
	chromium_failure_reason.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	chromium_failure_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chromium_failure_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chromium_failure_reason.modulate = Color(1, 1, 1, 0.75)
	chromium_failure.add_child(chromium_failure_reason)
	var actions := HFlowContainer.new()
	actions.alignment = FlowContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("h_separation", 12)
	actions.add_theme_constant_override("v_separation", 12)
	chromium_failure.add_child(actions)
	chromium_restart_button = Button.new()
	chromium_restart_button.text = "Restart Chromium"
	chromium_restart_button.pressed.connect(func():
		var chromium: Node = host.chromiums.get(int(key.substr(1)))
		if chromium != null: chromium.restart())
	actions.add_child(chromium_restart_button)
	chromium_reload_button = Button.new()
	chromium_reload_button.text = "Reload page"
	chromium_reload_button.pressed.connect(func():
		var chromium: Node = host.chromiums.get(int(key.substr(1)))
		if chromium != null: chromium.reload_failed_page())
	actions.add_child(chromium_reload_button)
	chromium_close_button = Button.new()
	chromium_close_button.text = "Close"
	# A stopped browser has no page state left to lose: close without asking.
	chromium_close_button.pressed.connect(func():
		if host.session_end_warning([int(key.substr(1))]).is_empty(): host.close_chromium_session(int(key.substr(1)))
		else: _confirm_chromium_close())
	actions.add_child(chromium_close_button)


func _confirm_chromium_close() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = 'Close chromium?'
	dialog.ok_button_text = 'Close chromium'
	dialog.dialog_text = tr('Closing this chromium window discards unsaved page state in its tabs.') + host.session_end_warning([int(key.substr(1))])
	# Modal dialogs belong to the host window. Inside the canvas this one would
	# make the host window refuse all input, including the clicks it forwards.
	host.add_child(dialog)
	dialog.confirmed.connect(
		func():
			host.close_chromium_session(int(key.substr(1)))
			dialog.queue_free(),
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(440, 140))


func _input(event: InputEvent) -> void:
	var sheet_position: Vector2 = get_viewport().canvas_transform.affine_inverse() * event.position if event is InputEventMouse else Vector2.ZERO
	# Hovering another tab hides this window mid-drag; its release must still land.
	if not is_visible_in_tree() and not (_pressed or _resizing):
		return
	if (
		event is InputEventKey and event.pressed
		and event.keycode == KEY_ESCAPE and (_pressed or _resizing)
	):
		abort_drag()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed and (_pressed or _resizing):
			var finished_resize := _resizing
			if finished_resize: host.workspace_view.agent_links.tools.finish_edit()
			if _transfer:
				host.application.finish_drag(host.workspace_view.pointer_screen)
			elif _dragging:
				host.workspace_view.finish_window_move(key)
			_cancel_drag()
			if finished_resize: host.session_backend.move_pane(host, key, Vector2.INF)
			# Let the header receive its release and relinquish GUI capture.
		elif event.pressed:
			var point: Vector2 = host \
					.workspace_view \
					.canvas_root \
					.get_global_transform() \
					.affine_inverse() * sheet_position
			var touch := bool(event.get_meta("direct_touch", false))
			var target: String = host.workspace_view.resize_window_at(point, touch)
			if target.is_empty(): target = host.workspace_view.window_at(point)
			if target != key:
				return
			if host.pane_focus != key:
				host.focus_pane.call_deferred(key)
			_resize_edges = _edge_at(get_global_transform().affine_inverse() * sheet_position, touch)
			if _resize_edges != Vector2.ZERO:
				host.workspace_view.agent_links.tools.sync()
				host.workspace_view.agent_links.tools.begin_edit()
				host.workspace_view.anchor_physics_pane(key)
				_resizing = true
				_press = sheet_position
				_start_rect = layout_rect()
				host.focus_pane(key)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and (_pressed or _resizing):
		var delta: Vector2 = sheet_position - _press
		if _resizing:
			host.workspace_view.set_window_rect(key, _resize_rect(delta), true)
		elif _dragging or delta.length() > 6:
			if not _dragging:
				host.workspace_view.anchor_physics_pane(key)
				host.workspace_view.moving = key
			_dragging = true
			# Canvas pixels move the window; the desktop pointer finds drop targets.
			_drag_to(host.workspace_view.pointer_screen, delta)
		get_viewport().set_input_as_handled()


func _stop_edge_pan() -> void:
	_edge_pan_held = 0.0
	set_process(false)


## A held pointer sends no motion: keep panning while it rests at an edge.
func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("WorkspacePane", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	if not _dragging or _transfer or _resizing or not is_visible_in_tree():
		_stop_edge_pan()
		return
	var view: Control = host.workspace_view
	var push: Vector2 = view.edge_pan_push()
	if push == Vector2.ZERO:
		_edge_pan_held = 0.0
		return
	# Dwell, then ease into scrolling. Never catch up with a jump after a stall.
	var previous := _edge_pan_held
	_edge_pan_held += minf(dt, .05)
	var travel: float = view.edge_pan_travel(_edge_pan_held) - view.edge_pan_travel(previous)
	if travel <= 0.0 or not view.edge_pan(key, push * travel):
		return
	# The pointer stays put on screen while the canvas beneath it moves.
	_drag_to(view.pointer_screen, view.layout_point(view.pointer_screen) - _press)


## A still copy of this window for a tab switch to fly: its frame, title bar
## and a chromium's page.
##
## A terminal's background and text fly as pieces of their own, so the copy
## leaves the terminal out.
##
## A duplicate's mod views hold no mod of their own: the header and title they
## paint would vanish for the length of a transition. Paint the originals'.
static func mirror_mod_views(source: Node, copy: Node) -> void:
	if source.is_class("ModView") and copy.is_class("ModView"):
		copy.mirror(source)
		copy.process_mode = Node.PROCESS_MODE_DISABLED
	for index in mini(source.get_child_count(), copy.get_child_count()):
		mirror_mod_views(source.get_child(index), copy.get_child(index))


func still_copy() -> Control:
	# Retain custom drawing (notably Chromium's toolbar background), as well
	# as independent shader/style state, before the live session is replaced.
	var page_sources: Array = [_chromium_source] if is_instance_valid(_chromium_source) else []
	var copy: Control = preload("res://scenes/RetainedPresentation.gd").control(self, page_sources)
	copy.position = Vector2.ZERO
	copy.scale = Vector2.ONE
	copy.pivot_offset = Vector2.ZERO
	copy.visible = true
	mirror_mod_views(self, copy)
	# The leaving tab may already be hidden when its retained frame is captured.
	var title := copy.get_node_or_null("PaneTitle") as Label
	if title != null:
		title.visible = size.y >= title.position.y + title.size.y * title.scale.y
	if not host.is_terminal_pane(key) and not video_layer:
		return copy
	# Copies get names of their own; the tree keeps its shape.
	var steps: Array[int] = []
	var node: Node = texture
	while node != self:
		steps.push_front(node.get_index())
		node = node.get_parent()
	var content: Node = copy
	for step in steps:
		content = content.get_child(step)
	if video_layer:
		# A capture has no video layer beneath it: draw the page itself.
		(content as TextureRect).material = _page_material
		var overlay := content.get_child(chromium_frozen_overlay.get_index()) as CanvasItem
		overlay.material = null
		overlay.use_parent_material = true
		return copy
	# Terminal ink is captured separately from the frame.
	(content as TextureRect).hide()
	(content as TextureRect).material = null
	(content as TextureRect).texture = null
	return copy
