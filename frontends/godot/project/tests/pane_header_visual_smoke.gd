extends SceneTree
## Graphical pixel comparison against the prior native toolbar primitives.
const Icons := preload("res://scenes/PaneIcons.gd")
func _initialize() -> void:
 call_deferred("run")

func run() -> void:
 var viewport := SubViewport.new()
 viewport.size = Vector2i(400, 160)
 viewport.transparent_bg = true
 viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
 root.add_child(viewport)
 var theme: Theme = load("res://scenes/PaneHeaderTheme.tres")
 var reference := HBoxContainer.new()
 reference.theme = theme
 reference.size = Vector2(400, 30)
 viewport.add_child(reference)
 var title := Control.new()
 title.custom_minimum_size.x = 60
 title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 reference.add_child(title)
 var textures: Array[Texture2D] = [Icons.filetree(), Icons.chromium()]
 for down in [false, true]:
  var divider := '<path d="M3 12h18"/>' if down else '<path d="M12 3v18"/>'
  textures.append(DPITexture.create_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/>' + divider + '</g></svg>', 28.0 / 24.0))
 textures.append(Icons.close())
 for texture in textures:
  var button := Button.new()
  button.icon = texture
  button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
  button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
  button.mouse_filter = Control.MOUSE_FILTER_IGNORE
  reference.add_child(button)
 var header: Control = load("res://scenes/PaneHeader.tscn").instantiate()
 header.position.y = 40
 header.size = Vector2(400, 30)
 viewport.add_child(header)
 header.set_hovered(true)
 var native_title := Label.new()
 native_title.theme = theme
 native_title.position.y = 80
 native_title.size = Vector2(400, 30)
 native_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
 native_title.text = "Terminal title — ~/workspace"
 viewport.add_child(native_title)
 var mod_title := preload("res://scenes/mods/PaneTitle.gd").new()
 mod_title.theme = theme
 mod_title.position.y = 120
 mod_title.size = Vector2(400, 30)
 mod_title.text = native_title.text
 viewport.add_child(mod_title)
 await process_frame
 await process_frame
 await RenderingServer.frame_post_draw
 var image := viewport.get_texture().get_image()
 var difference := 0.0
 var ink := 0.0
 for y in 30:
  for x in 400:
   var a := image.get_pixel(x, y)
   var b := image.get_pixel(x, y + 40)
   ink += a.a
   difference += absf(a.a - b.a)
 var ratio := difference / maxf(ink, 1)
 print("Native/mod toolbar alpha difference: %.4f" % ratio)
 # DPITexture and the mod's 2x SVG rasterizer have different edge sampling.
 var passed := ratio < 0.15 and ink > 100
 difference = 0.0
 ink = 0.0
 for y in 30:
  for x in 400:
   var a := image.get_pixel(x, y + 80)
   var b := image.get_pixel(x, y + 120)
   ink += a.a
   difference += absf(a.a - b.a)
 ratio = difference / maxf(ink, 1)
 print("Native/mod title alpha difference: %.4f" % ratio)
 passed = passed and ratio < 0.15 and ink > 100
 print("PANE_HEADER_VISUAL_PASS" if passed else "PANE_HEADER_VISUAL_FAIL")
 viewport.queue_free()
 await process_frame
 quit(0 if passed else 1)
