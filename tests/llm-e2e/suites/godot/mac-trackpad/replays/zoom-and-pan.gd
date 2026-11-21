extends "../../../../replay/mac_pinch.gd"
func play() -> void:
	for path in ["", "flat-2d"]:
		await prepare(path)
		await say("Zoom and pan: move the imaginary zoom point with both fingers")
		for step in 12: await gesture(1.02,Vector2(4,2))
		check(imaginary.distance_to(mouse)>50,"Intentional pan moves the anchor away from the mouse")
		await say("Pause magnification, continue panning, then zoom again without lifting")
		for step in 10: await gesture(1.0,Vector2(-3,2))
		var resumed_anchor := imaginary
		for step in 10: await gesture(1.015)
		check(imaginary==resumed_anchor,"Resumed zoom retains the moved anchor")
		for step in 8: await gesture(1.0/1.02,Vector2(-2,-3))
		await say("Lift both fingers: the next gesture starts at the mouse again")
		imaginary = mouse
		anchored_content = host.workspace_view.canvas_point_at(mouse)
		content_marker.position = anchored_content
		for step in 6: await gesture(1.015)
	check(anchor_error<2.0,"Every frame preserves the moving anchor in Flat and Flat 2D")
	print("MAC_ZOOM_AND_PAN_PASS")
