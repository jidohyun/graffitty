extends SceneTree
## A departing Chromium must retain its custom toolbar paint and shader state.
var failures := 0

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func viewport() -> SubViewport:
	var result := SubViewport.new()
	result.size = Vector2i(640, 180)
	result.transparent_bg = true
	result.use_hdr_2d = true
	result.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(result)
	return result

func run() -> void:
	var effects := preload("res://scenes/TerminalEffects.gd")
	var departing := Vector3(8.0, 0.0263, 1.0)
	var incoming := Vector3(0.0, 100.0, 0.0)
	check(effects.blend_lens(departing, incoming, 0.0).is_equal_approx(departing), "Session binding preserves the departing optical state")
	var first: Vector3 = effects.blend_lens(departing, incoming, smoothstep(0.0, 1.0, 1.0 / 120.0))
	check(first.x / first.y > departing.x / departing.y * .999, "A distant destination cannot abruptly remove departure blur")
	check(effects.blend_lens(departing, incoming, 1.0).is_equal_approx(incoming), "Optical transition reaches the incoming state")
	var live := viewport()
	var chrome := preload("res://scenes/ChromiumChrome.gd").new()
	live.add_child(chrome)
	chrome.size = Vector2(640, 180)
	chrome.tabs.reconcile([{"id": 1, "title": "Markdown Preview", "url": "", "favicon": ""}], 1)
	for i in 20: await process_frame
	var retained := viewport()
	retained.add_child(preload("res://scenes/RetainedPresentation.gd").control(chrome))
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	var before := live.get_texture().get_image()
	var after := retained.get_texture().get_image()
	check(before.get_data() == after.get_data(), "Retained Chromium matches the live toolbar pixel-for-pixel")
	chrome.tab_frame.material.set_shader_parameter("frame_color", Color.RED)
	chrome.queue_free()
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	check(after.get_data() == retained.get_texture().get_image().get_data(), "Live chrome changes and teardown cannot alter the retained toolbar")
	quit(1 if failures else 0)

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
