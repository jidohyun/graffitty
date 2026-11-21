extends RefCounted
## Node-supplied display symbols; independent of host delivery status.
## Share the application's cache lifetime so textures retire before the renderer.
static func _textures() -> Dictionary:
	var cache: Dictionary = preload("res://scenes/PaneIcons.gd")._cache()
	var key := "nodeicon_textures"
	if not cache.has(key): cache[key] = {}
	return cache[key]

static func _fonts() -> Dictionary:
	var cache: Dictionary = preload("res://scenes/PaneIcons.gd")._cache()
	var key := "nodeicon_fonts"
	if not cache.has(key): cache[key] = {}
	return cache[key]

static func validate(value: Variant) -> Dictionary:
	return preload("res://scenes/GraphPorts.gd")._core().validate_icon(value)

static func font(spec: Dictionary) -> Font:
	var fonts := _fonts()
	var family: String = spec.get("font", "")
	if family.is_empty(): return ThemeDB.fallback_font
	if not fonts.has(family):
		if fonts.size() >= 64: fonts.clear()
		var result := SystemFont.new()
		result.font_names = PackedStringArray([family])
		fonts[family] = result
	return fonts[family]

static func texture(spec: Dictionary) -> Texture2D:
	var textures := _textures()
	var svg: String = spec.get("svg", "")
	if svg.is_empty(): return null
	if not textures.has(svg):
		if textures.size() >= 64: textures.clear()
		var image := Image.new()
		# Override intrinsic dimensions so node artwork stays icon-sized.
		var root := RegEx.create_from_string("<svg\\b[^>]*>")
		var found := root.search(svg)
		if found == null: return null
		var header := RegEx.create_from_string("\\s(?:width|height)\\s*=\\s*(['\"])[^'\"]*['\"]").sub(found.get_string(), "", true)
		header = header.trim_suffix(">") + ' width="32" height="32">'
		var sized := svg.substr(0, found.get_start()) + header + svg.substr(found.get_end())
		textures[svg] = ImageTexture.create_from_image(image) if image.load_svg_from_string(sized) == OK else null
	return textures[svg]
