extends RefCounted
## SVG textures re-rasterize for viewport DPI/oversampling. The application
## owns cached textures so they are released before renderer shutdown.

static func _cache() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var application := tree.root.get_node_or_null("TerminalApplication") if tree != null else null
	return application.pane_icon_cache if application != null else {}


static func _texture(key: String, path: String, scale: float) -> Texture2D:
	var cache := _cache()
	if not cache.has(key):
		if FileAccess.file_exists(path):
			var source := FileAccess.get_file_as_string(path)
			if not source.is_empty():
				cache[key] = DPITexture.create_from_string(source, scale)
		if not cache.has(key):
			cache[key] = _imported(path, scale)
	return cache[key]


## Standard exports retain VRAM-compressed imports, not raw SVG bytes. They are
## rasterized at the SVG's own size, so apply the scale DPITexture would.
static func _imported(path: String, scale: float) -> Texture2D:
	var texture: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path, "Texture2D") else null
	var image := _rgba(texture) if texture != null and not is_equal_approx(scale, 1.0) else null
	if image == null: return texture
	var size := Vector2i((texture.get_size() * scale).round())
	# Keep up to 2x pixels for HiDPI screens; never upsample the raster import.
	var pixels := Vector2i(mini(image.get_width(), size.x * 2), mini(image.get_height(), size.y * 2))
	if pixels != image.get_size(): image.resize(pixels.x, pixels.y, Image.INTERPOLATE_LANCZOS)
	var result := ImageTexture.create_from_image(image)
	result.set_size_override(size)
	return result


## An editable copy; compressed images reject convert() and pixel access.
static func _rgba(icon: Texture2D) -> Image:
	var image := icon.get_image()
	if image == null or image.is_empty(): return null
	image = image.duplicate() as Image
	if image.is_compressed() and image.decompress() != OK: return null
	image.clear_mipmaps()
	image.convert(Image.FORMAT_RGBA8)
	return image


static func chromium() -> Texture2D:
	return _texture("chromium", "res://assets/icons/chromium.svg", 24.0 / 512.0)


static func monitor() -> Texture2D:
	return _texture("monitor", "res://assets/icons/stats.svg", 28.0 / 24.0)


static func filetree() -> Texture2D:
	return _texture("filetree", "res://scenes/icons/folder-tree.svg", 1.0)


static func cpu() -> Texture2D:
	return _texture("cpu", "res://assets/icons/cpu.svg", 2.0)


static func ram() -> Texture2D:
	return _texture("ram", "res://assets/icons/ram.svg", 2.0)


## Use artwork matched to the menu renderer.
##
## - Godot popups use white icons on the dark theme.
## - Native macOS menus need black icons because they cannot tint them.
## - Native Windows menus omit icons. They draw the straight-alpha bitmaps opaque.
static func menu_icon(menu: PopupMenu, icon: Texture2D) -> Texture2D:
	if not menu.is_native_menu(): return icon
	if OS.get_name() == "Windows": return null
	return menu_silhouette(icon)


static func menu_silhouette(icon: Texture2D) -> Texture2D:
	if icon == null: return null
	var cache := _cache()
	if not icon is DPITexture:
		var key := "menu:%d" % icon.get_instance_id()
		if not cache.has(key):
			var image := _rgba(icon)
			if image != null: image.adjust_bcs(0.0, 1.0, 1.0) # Zero RGB, keep alpha.
			cache[key] = ImageTexture.create_from_image(image) if image != null else null
		return cache[key]
	# Native menus need black artwork; preserve the original white title icons.
	var dpi_icon := icon as DPITexture
	var source := dpi_icon.get_source().replace('"white"', '"#000000"')
	var svg_key := "menu:" + source + str(dpi_icon.base_scale)
	if not cache.has(svg_key):
		cache[svg_key] = DPITexture.create_from_string(source, dpi_icon.base_scale)
	return cache[svg_key]


static func keyboard() -> Texture2D:
	return _texture("keyboard", "res://scenes/icons/keyboard.svg", 1.0)

static func microphone() -> Texture2D:
	return _texture("microphone", "res://scenes/icons/microphone.svg", 1.0)

static func stop() -> Texture2D:
	return _texture("stop", "res://scenes/icons/stop.svg", 1.0)

static func trash() -> Texture2D:
	return _texture("trash", "res://scenes/icons/trash-2.svg", 1.0)

static func close() -> Texture2D:
	return _texture("close", "res://scenes/icons/x.svg", 1.0)
