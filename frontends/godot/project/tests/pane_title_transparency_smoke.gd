extends SceneTree
## Real renderer test: enlarged title coverage dims ink instead of discarding it.
var failed := false
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
 print(("PASS " if ok else "FAIL ") + message)
 failed = failed or not ok
func run() -> void:
 if DisplayServer.get_name() == "headless":
  push_error("This pixel test requires a renderer, not --headless")
  quit(1)
  return
 var viewport := SubViewport.new()
 viewport.size = Vector2i(64, 64)
 viewport.transparent_bg = true
 viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
 root.add_child(viewport)
 var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
 image.fill(Color.WHITE)
 var texture := TextureRect.new()
 texture.texture = ImageTexture.create_from_image(image)
 texture.size = Vector2(64, 64)
 var material := ShaderMaterial.new()
 material.shader = load("res://scenes/terminal_composite.gdshader")
 material.set_shader_parameter("content_clip_top", .5)
 texture.material = material
 viewport.add_child(texture)
 await process_frame
 await RenderingServer.frame_post_draw
 var pixels := viewport.get_texture().get_image()
 var covered := pixels.get_pixel(32, 8)
 var uncovered := pixels.get_pixel(32, 56)
 check(absf(covered.a - .5) < .03, "Terminal pixels under the enlarged title retain 50%% alpha: %s" % covered)
 check(uncovered.a > .97, "Terminal content below the title stays opaque")
 material.set_shader_parameter("content_clip_top", 0.0)
 await process_frame
 await RenderingServer.frame_post_draw
 pixels = viewport.get_texture().get_image()
 check(pixels.get_pixel(32, 8).a > .97, "Normal title size leaves terminal content unchanged")
 viewport.queue_free()
 await process_frame
 quit(1 if failed else 0)
