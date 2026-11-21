extends "res://tests/mods_fixture.gd"
## Rendered check; needs a real renderer, so run it windowed (not --headless),
## e.g. `godot --rendering-method mobile --path . --script <this>`.
##
## A floating embedded (touch) panel is translucent once: the scene behind it
## shows through blurred, the title and body share one tint, and its rounded
## corners show the scene rather than an opaque square window background.
func run() -> void:
	setup(true)
	root.size = Vector2i(900, 700)
	var stripes := Control.new()
	stripes.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stripes.draw.connect(func():
		for i in 90:
			stripes.draw_rect(Rect2(i * 10, 0, 10, 700), Color.RED if i % 2 == 0 else Color.GREEN))
	host.layout_root.add_child(stripes)
	host.layout_root.move_child(stripes, 0)
	var dialog: Window = PanelWindow.open(host, "sessions")
	await settle()
	dialog.float_native(Vector2(200, 150))
	dialog.size = Vector2i(400, 300)
	dialog.position = Vector2i(200, 150)
	for i in 20: await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if OS.has_environment("PROBE_OUT"): image.save_png(OS.get_environment("PROBE_OUT"))
	var r := Rect2i(dialog.position, dialog.size)
	check(dialog.is_embedded() and dialog.transparent_bg, "Floating touch panel is an embedded window with a transparent viewport")
	var surface: Color = dialog.SURFACE
	var body := image.get_pixelv(r.get_center())
	var title := image.get_pixelv(r.position + Vector2i(r.size.x / 3, -8))
	check(maxf(absf(body.r - surface.r), absf(body.g - surface.g)) > 0.04, "Body is not the opaque surface colour: %s" % body)
	check(body.r > body.b + 0.02 and body.g > body.b + 0.02, "The red/green scene shows through the body: %s" % body)
	check(absf(body.r - title.r) < 0.03 and absf(body.g - title.g) < 0.03, "Title and body share one tint: %s vs %s" % [title, body])
	var neighbour := image.get_pixelv(r.get_center() + Vector2i(10, 0))
	check(absf(body.r - neighbour.r) < 0.06 and absf(body.g - neighbour.g) < 0.06, "The scene behind is blurred, not sharp stripes: %s vs %s" % [body, neighbour])
	for corner in [r.position + Vector2i(1, r.size.y - 2), r.position + Vector2i(r.size.x - 2, r.size.y - 2)]:
		var pixel := image.get_pixelv(corner)
		check(maxf(pixel.r, pixel.g) > 0.5, "Rounded corner %s shows the scene, not a square window background: %s" % [corner, pixel])
	finish("EMBEDDED_PANEL_RENDER")
