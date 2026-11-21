extends "res://tests/client_scenarios/workspace.gd"
## The phone's federation must retain the server's connected-pane placement.

func filetree_layout() -> void:
	host.world.fx_enabled = false
	if not current_tree().get("tiling", false): await toggle_tiling()
	var source: String = host.pane_focus
	var source_id := int(source.substr(1))
	for tiled in [true, false]:
		if bool(current_tree().get("tiling", false)) != tiled: await toggle_tiling()
		var reply: Dictionary = await manager.federation.remote_call(source_id, "filetree.toggle", {})
		if not expect(not reply.has("error"), "Server opens connected filetree"): return
		var tree: String = reply.result.pane
		if not await until(func(): return view.pane_rects.has(tree), "Filetree arrives through the phone's federation"): return
		await wait(.5)
		expect(view.pane_rects[tree].position.x < view.pane_rects[source].position.x, "Filetree opens left of its owner in %s mode" % ("tiled" if tiled else "floating"))
		if tiled:
			expect(view.pane_rects[tree].end.x <= view.pane_rects[source].position.x + 1, "Tiled filetree precedes the source without overlap")
			var opened: Dictionary = await manager.federation.remote_call(int(tree.substr(1)), "filetree.open_file", {"path": settings.filetree_fixture})
			if not expect(not opened.has("error"), "Server opens connected viewer"): return
			var viewer: String = opened.result.pane
			if not await until(func(): return view.pane_rects.has(viewer), "Viewer arrives through federation"): return
			await wait(.5)
			expect(view.pane_rects[viewer].end.y <= view.pane_rects[source].position.y + 1, "File viewer opens above the source")
			expect(view.pane_rects[tree].end.x <= view.pane_rects[source].position.x + 1, "Opening a viewer keeps the filetree on the left")
			manager.federation.send_action("close", int(viewer.substr(1)))
			await until(func(): return not view.pane_rects.has(viewer), "Close test viewer")
		await manager.federation.remote_call(source_id, "filetree.toggle", {})
		await until(func(): return not view.pane_rects.has(tree), "Close test filetree")
