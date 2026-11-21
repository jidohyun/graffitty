extends "tab-strip-layout.gd"

func play() -> void:
	await open_tabs(6)
	await resize_tabs(110)
	await select_tab(1)
	await settled()
	var first: int = host.get_tabs()[0].id
	var width: float = tab_button(0).size.x
	await click(on(tab_button(1).get_node("Close")))
	await settled()
	check(host.get_tabs().size() == 5, "Touch close removes one tab")
	check(tab_strip()._closing_touch, "Touch close uses Chromium's touch timer")
	await point_at(Vector2(400, 300))
	await create_timer(.8).timeout
	check(is_equal_approx(tab_button(0).size.x, width), "Touch widths stay fixed when pointer moves away")
	samples.clear()
	process_frame.connect(sample)
	await create_timer(1.6).timeout
	await settled()
	process_frame.disconnect(sample)
	check(tab_button(0).size.x > width + 10, "Touch close expands after two seconds")
	check(intermediate_widths(first, width, tab_button(0).size.x) >= 3, "Touch expansion animates through intermediate widths")
	save_samples("touch-close-bounds")
	(await screen_image()).save_png(evidence_path("touch-close-settled.png"))
