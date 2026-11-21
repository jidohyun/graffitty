extends "../../../../tests/llm-e2e/replay/replay.gd"
## Verify the renamed CEF capture switch and rebuilt renderer helpers together.


func play() -> void:
	OS.set_environment("GODOT_CHROMIUM_AUDIT", "1")
	await camera_at_rest()
	var chromium: Node = await host.create_chromium_session("data:text/html,<style>body{background:cyan}</style><select><option>One</option><option>Two</option></select>")
	var until := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < until:
		await process_frame
	check(chromium.chromium_ready, "Rebuilt Chromium starts")
	if not chromium.chromium_ready:
		chromium.close()
		return
	var first: Dictionary = {}
	until = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < until:
		first = (await chromium.request("chrome-state")).get("result", {})
		if int(first.get("gpuFrames", 0)) > 0 and first.get("tabBridgeReady", false) and not first.get("tabs", [{}])[0].get("loading", true):
			break
		await process_frame
	check(int(first.get("gpuFrames", 0)) > 0, "Renamed CEF switch enables GPU frame delivery")
	var first_id := int(first.get("chromiumId", 0))
	check(first_id > 0, "Initial Chrome tab exists")
	var select: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "document.querySelector('select').selectedIndex=1; document.querySelector('select').value", "returnByValue": true}})
	check(select.get("result", {}).get("result", {}).get("value") == "Two", "Renderer helpers preserve standard page controls")
	await chromium.request("tab-new")
	var second: Dictionary = {}
	until = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < until:
		second = (await chromium.request("chrome-state")).get("result", {})
		if second.get("tabBridgeReady", false) and second.get("tabs", []).size() == 2 and int(second.get("chromiumId", 0)) != first_id:
			break
		await process_frame
	var second_id := int(second.get("chromiumId", 0))
	check(second.get("tabs", []).size() == 2 and second_id != first_id, "Private tab bridge creates and selects another tab")
	for id in [first_id, second_id, first_id]:
		await chromium.request("tab-select", {"chromium_id": id})
		var state: Dictionary = {}
		until = Time.get_ticks_msec() + 10000
		while Time.get_ticks_msec() < until:
			state = (await chromium.request("chrome-state")).get("result", {})
			if int(state.get("capturedPageId", 0)) == id and int(state.get("chromiumId", 0)) == id:
				break
			await process_frame
		check(int(state.get("capturedPageId", 0)) == id, "GPU capture follows selected tab %d" % id)
		check(state.get("presentationAudited", false), "Native presentation audit is enabled")
		for counter in ["visibleWindows", "unexpectedWindowOrders", "unexpectedKeyEvents", "unexpectedActivations", "errors"]:
			check(int(state.get(counter, -1)) == 0, "%s stays zero" % counter)
	check(chromium.texture.get_width() > 0, "Godot receives the chromium texture")
	chromium.close()
