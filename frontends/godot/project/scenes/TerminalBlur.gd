extends Node
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
## Linear-light, premultiplied Gaussian pyramid shared by the active sheet.
const BlurShader := preload("res://scenes/terminal_blur.gdshader")
var viewports: Array[SubViewport] = []
var source: Texture2D
var source_size := Vector2i.ZERO
var target: ShaderMaterial


func bind(material: ShaderMaterial) -> void:
	if target == material:
		return
	if target != null:
		RenderUpdates.uniform(target, "blur_pyramid_ready", false)
	target = material
	source = null


func update(enabled: bool) -> void:
	if target == null:
		return
	var texture: Texture2D = target.get_shader_parameter("terminal_tex")
	if enabled and texture != null:
		var size := Vector2i(texture.get_size())
		if texture != source or size != source_size:
			rebuild(texture, size)
	for viewport in viewports:
		RenderUpdates.set_enabled(viewport, enabled)
	RenderUpdates.uniform(target, "blur_pyramid_ready", enabled and not viewports.is_empty())


func rebuild(texture: Texture2D, size: Vector2i) -> void:
	for viewport in viewports:
		viewport.queue_free()
	viewports.clear()
	source = texture
	source_size = size
	var input := texture
	for level in 4:
		var level_size := Vector2i(maxi(size.x >> (level + 1), 1), maxi(size.y >> (level + 1), 1))
		for horizontal in [true, false]:
			var viewport := SubViewport.new()
			viewport.name = "Blur%d%s" % [level + 1, "H" if horizontal else "V"]
			viewport.size = level_size
			viewport.disable_3d = true
			viewport.transparent_bg = true
			viewport.use_hdr_2d = true
			RenderUpdates.configure(viewport)
			add_child(viewport)
			var rect := TextureRect.new()
			rect.texture = input
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.size = level_size
			var material := ShaderMaterial.new()
			material.shader = BlurShader
			RenderUpdates.uniform(material, "input_texture", input)
			RenderUpdates.uniform(material,
				"axis",
				Vector2(1.0 / level_size.x, 0) if horizontal else Vector2(0, 1.0 / level_size.y),
			)
			rect.material = material
			viewport.add_child(rect)
			viewports.append(viewport)
			input = viewport.get_texture()
		RenderUpdates.uniform(target, "terminal_blur_%d" % (level + 1), input)
