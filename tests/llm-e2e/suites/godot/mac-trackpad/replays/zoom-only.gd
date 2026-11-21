extends "../../../../replay/mac_pinch.gd"
func play() -> void:
	for path in ["", "flat-2d"]:
		await prepare(path)
		await say("Zoom only: keep the content under the mouse fixed")
		var start_zoom: float = host.workspace_view.navigation_zoom
		for step in 18: await gesture(1.025)
		check(host.workspace_view.navigation_zoom > start_zoom*1.5,"Pinch increases magnification")
		check(imaginary==mouse,"No pan intent keeps the zoom point at the mouse")
		for step in 18: await gesture(1.0/1.025)
		check(absf(host.workspace_view.navigation_zoom-start_zoom)<.001,"Reverse pinch restores scale without drifting")
	check(anchor_error<2.0,"Every frame preserves the mouse anchor in Flat and Flat 2D")
	print("MAC_ZOOM_ONLY_PASS")
