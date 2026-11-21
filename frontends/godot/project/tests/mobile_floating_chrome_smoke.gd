extends "res://tests/mods_fixture.gd"
## A floating mobile panel paints nothing but its rounded body and title: no
## backdrop may leak outside the rounded corners or along an edge.
##
## A bright plane behind the window makes any leak show as a non-body,
## non-plane colour. Needs a real renderer: run with --position -32000,-32000,
## not --headless.
const BODY := Color("202126")
const PLANE := Color(1, 0, 1)

func near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < .06 and absf(a.g - b.g) < .06 and absf(a.b - b.b) < .06

## The plane seen through the window's drop shadow: still clearly magenta.
## An opaque window backdrop (clear colour, white on Android) is grey instead.
func shows_plane(c: Color) -> bool:
	return c.r > .5 and c.b > .5 and c.g < .15

func run() -> void:
	setup(true)
	var plane := ColorRect.new()
	plane.color = PLANE
	plane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plane.z_index = -1
	root.add_child(plane)
	root.move_child(plane, 0)
	var dialog: Window = PanelWindow.open(host, "agents")
	await settle()
	dialog.float_native()
	await settle()
	for i in 6: await process_frame
	check(dialog.visible and dialog.transparent_bg and dialog.unresizable, "Floating mobile window is transparent and has no stock resize chrome")
	var image: Image = root.get_viewport().get_texture().get_image()
	var scale := root.get_viewport().get_screen_transform().get_scale().x
	var rect := Rect2(Vector2(dialog.position) * scale, Vector2(dialog.size) * scale)
	var out := OS.get_environment("GFT_CAPTURE_DIR")
	if out.is_empty(): out = OS.get_cache_dir()
	image.get_region(Rect2i(rect.grow(30 * scale)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))).save_png(out.path_join("mobile-floating-chrome.png"))
	# Just inside the bottom-right and bottom-left corners, outside the rounding.
	var leaks := 0
	for corner in [rect.end - Vector2(1.5, 1.5) * scale, Vector2(rect.position.x + 1.5 * scale, rect.end.y - 1.5 * scale)]:
		var c := image.get_pixelv(Vector2i(corner))
		if not shows_plane(c): leaks += 1
	check(leaks == 0, "Corner pixels outside the rounding show the plane behind the window, not a backdrop (%d leaks)" % leaks)
	# The right, left and bottom edge columns/rows, mid-way, are body colour.
	var edge_leaks := 0
	for point in [Vector2(rect.end.x - .5 * scale, rect.get_center().y), Vector2(rect.position.x + .5 * scale, rect.get_center().y), Vector2(rect.get_center().x, rect.end.y - .5 * scale)]:
		var c := image.get_pixelv(Vector2i(point))
		if not near(c, BODY): edge_leaks += 1
	check(edge_leaks == 0, "Edge pixels are the body colour with no lighter line (%d leaks)" % edge_leaks)
	# The title row above the body is the same chrome colour.
	var title := image.get_pixelv(Vector2i(Vector2(rect.get_center().x, rect.position.y - 12 * scale)))
	check(near(title, BODY), "Title chrome matches the body: %s" % title)
	print("MOBILE_FLOATING_CHROME_PASS" if failures.is_empty() else "MOBILE_FLOATING_CHROME_FAIL")
	quit(0 if failures.is_empty() else 1)
