extends "res://tests/workspace_render_updates_smoke.gd"
## No animated replay overlay: the observer must not prevent idle rendering.

func screen_image() -> Image:
	return root.get_texture().get_image()

func pixels() -> int:
	return hash(screen_image().get_data())

func color_pixels(blue: bool) -> int:
	var image := screen_image()
	var count := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			if color.g < 0.25 and ((color.b > 0.7 and color.r < 0.25) if blue else (color.r > 0.7 and color.b < 0.25)):
				count += 1
	return count

func chromium_checks() -> void:
	host.world.fx_enabled = false
	host.workspace_view.show_main()
	var chromium: Node = await host.create_chromium_session("about:blank", -1, true, "")
	check(chromium != null, "Create an embedded chromium using a supported URL")
	if chromium == null: return
	var deadline := Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline and (not chromium.chromium_ready or chromium.frames == 0):
		await wait(0.05)
	check(chromium.chromium_ready and chromium.frames > 0, "Real Chromium provides GPU frames to the embedded chromium")
	if not chromium.chromium_ready or chromium.frames == 0:
		chromium.close()
		return
	await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "document.body.style.cssText='margin:0;background:red'"}})
	await wait(1.0)
	check(color_pixels(false) > 100, "The red chromium page reaches the final window pixels")
	var first: int = chromium.frames
	var before := draws
	var response: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "document.body.style.background='blue'", "returnByValue": true}})
	check(not response.has("error"), "Chromium page can change without terminal input")
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and chromium.frames == first:
		await wait(0.05)
	await wait(0.2)
	check(chromium.frames > first and draws > before, "A new chromium GPU frame wakes composition")
	check(color_pixels(true) > 100 and color_pixels(false) < 20, "The blue page replaces red in the final window")
	await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression":
		"window.n=0;window.animation=setInterval(()=>{document.body.style.background=(++window.n%2)?'red':'blue'},80)"}})
	before = draws
	first = chromium.frames
	await wait(1.0)
	check(chromium.frames - first >= 5 and draws - before >= 5, "Chromium animation keeps delivering and composing frames")
	await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "clearInterval(window.animation)"}})
	host.close_chromium_session(chromium.session_id)
	await wait(2.0)
	before = draws
	await wait(1.0)
	check(draws - before <= 2, "Closing the animated chromium restores idle rendering: %d frames" % (draws - before))
