extends "../../../../replay/replay.gd"

func header_height(view: Control, pane: Control) -> float:
	return view.view_point(pane.position).distance_to(view.view_point(pane.position + Vector2(0, pane.body.position.y)))

func zoom_header(view: Control, pane: Control, pixels: float) -> void:
	await point_at(content(Vector2(.5, .5)))
	await pinch(pixels / header_height(view, pane))
	await camera_at_rest()
	if pixels > 30.0:
		# A magnified pane is larger than the viewport. Keep its top in view.
		view.navigation_center.y = pane.position.y + 100.0
		view._apply_navigation()
	await hold(.3)

func rendered_font_height(view: Control, pane: Control) -> float:
	var label: Label = view.pane_titles[pane.key]
	var font: Font = label.get_theme_font("font")
	var glyph_height := font.get_height(label.get_theme_font_size("font_size"))
	var top := label.get_global_transform() * Vector2.ZERO
	var bottom := label.get_global_transform() * Vector2(0, glyph_height)
	# A constant theme font size alone is insufficient: the camera can still
	# shrink its rendered glyphs. Measure their projected size on screen.
	if label.get_viewport() == view.canvas:
		return view.view_point(top).distance_to(view.view_point(bottom))
	return top.distance_to(bottom)

func play() -> void:
	await labelled_tabs(["RESOURCES"])
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var pane: Control = view.panes[key]
	var body_size: Vector2 = pane.body.size
	await zoom_header(view, pane, 30)
	var readable_height := rendered_font_height(view, pane)
	await say("Titles keep their readable screen font size; only icons use the threshold")
	await zoom_header(view, pane, 20)
	check(view.status_strips.has(key) and view.status_strips[key].visible, "StatusStrip appears before icons hide")
	var header: Control = await hover_header(key)
	check(not pane.compact_header and header.has_part("chromium"), "Icons remain visible above half size")
	# Header-local, so it names the same spot of the title row at every zoom.
	var split_spot: Vector2 = header.part_rect("split_right").get_center()
	var above := 0.0
	for height in [45.0, 30.0, 20.0, 15.1, 14.9, 12.0, 8.0, 20.0, 30.0]:
		await zoom_header(view, pane, height)
		check(view.pane_titles[key].is_visible_in_tree() and view.pane_titles[key].modulate.a == 1, "Title remains visible at %s px" % height)
		check(absf(rendered_font_height(view, pane) - readable_height) <= 1.0, "Title keeps its readable on-screen font size at %s px (actual %.2f, expected %.2f)" % [height, rendered_font_height(view, pane), readable_height])
		check(view._pane_screen_rect(pane).grow(1.0).encloses(view.title_screen_rect(view.pane_titles[key])), "Title remains inside the pane frame at %s px" % height)
		check(is_zero_approx(pane.texture.offset_top) and is_zero_approx(pane.texture.offset_bottom), "Title masks top rows without moving terminal bottom at %s px" % height)
		check(pane.body.size == body_size, "Zoom does not resize the terminal grid at %s px" % height)
		var compact: bool = header_height(view, pane) < 15
		await hover_header(key)
		check(pane.compact_header == compact and header.has_part("chromium") == (not compact) and header.has_part("split_right") == (not compact), "Only icon visibility switches at half size")
		var action: String = header.action_at(header.get_global_transform() * split_spot)
		check(action == "split_right" if not compact else action in ["", "close"] and not pane.secondary_split_at(header.get_global_transform() * split_spot), "Hidden icons cannot intercept clicks (%s)" % action)
		if height == 15.1: above = rendered_font_height(view, pane)
		if height == 14.9:
			check(absf(rendered_font_height(view, pane) - above) <= 1.0, "Title font size stays unchanged across the icon threshold")
	check(not view.status_strips[key].visible, "Full size hides StatusStrip independently")
