extends "../../../../tests/llm-e2e/replay/replay.gd"
## Chromium reflows with its pane rather than scaling a fixed-size page image.
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func play() -> void:
	await camera_at_rest()
	var chromium: Node = await host.create_chromium_session("data:text/html,<style>body{background:%2318222e;color:white;font:24px sans-serif}div{width:100px;height:100px;background:cyan}</style><h1>Responsive chromium</h1><div></div><p>A square stays square when the pane is narrow.</p>")
	var until := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < until:
		await process_frame
	check(chromium.chromium_ready, "Owned Chromium fixture starts")
	if not chromium.chromium_ready:
		chromium.close()
		return
	var view: Control = host.workspace_view
	var key := "%%%d" % chromium.session_id
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	var pane: Control = view.panes[key]
	for extent in [Vector2(900, 650), Vector2(360, 800), Vector2(600, 450)]:
		# Same path as the pane edge drag, without resizing the outer window.
		view.set_window_rect(key, Rect2(Vector2(20, 90), extent), true)
		await check_capture(chromium, pane, "pane resize")
	group.tree["tiling"] = true
	view.refresh()
	for width in [900, 533]:
		root.size = Vector2i(Vector2(width, 900) * root.content_scale_factor)
		await check_capture(chromium, pane, "native resize with tiling")
	chromium.close()


func check_capture(chromium: Node, pane: Control, label: String) -> void:
	await hold(0.2)
	var wanted := Vector2i(pane.texture.size.round())
	var actual := Vector2i.ZERO
	var frame := Vector2.ZERO
	var until := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < until:
		var response: Dictionary = await chromium.request("cdp", { "method": "Runtime.evaluate", "params": { "expression": "[innerWidth,innerHeight]", "returnByValue": true } })
		var value: Array = response.get("result", {}).get("result", {}).get("value", [])
		if value.size() == 2:
			actual = Vector2i(int(value[0]), int(value[1]))
		frame = chromium.texture.get_size()
		if actual == wanted and frame.y > 0 and absf(frame.x / frame.y - float(wanted.x) / wanted.y) < 0.01:
			break
		await hold(0.15)
	check(actual == wanted, "%s: Chromium viewport matches pane content %s (actual %s)" % [label, wanted, actual])
	check(frame.y > 0 and absf(frame.x / frame.y - float(wanted.x) / wanted.y) < 0.01, "GPU frame preserves content aspect ratio (%s)" % frame)
	check(pane.texture.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "Frames are never stretched out of proportion")
