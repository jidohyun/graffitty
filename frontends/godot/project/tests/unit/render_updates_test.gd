extends "res://tests/unit/test_case.gd"
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
const Pane := preload("res://scenes/WorkspacePane.gd")
const Chromium := preload("res://scenes/remote/RemoteChromiumSession.gd")


class Decoder extends RefCounted:
	var frames: Array[Dictionary] = []
	func consumed() -> int: return 0
	func take_frame() -> Dictionary: return frames.pop_front() if not frames.is_empty() else {}


func _nv12(width: int, height: int) -> Dictionary:
	var luma := PackedByteArray()
	luma.resize(width * height)
	var chroma := PackedByteArray()
	chroma.resize(((width + 1) >> 1) * ((height + 1) >> 1) * 2)
	return {"width": width, "height": height, "y": luma, "uv": chroma}


func test_changes_only_viewport_sleeps_through_frames_without_changes() -> void:
	var canvas := SubViewport.new()
	var world := SubViewport.new()
	RenderUpdates.configure(canvas, true)
	RenderUpdates.configure(world)
	var now := Time.get_ticks_msec()
	RenderUpdates.prepare(canvas)
	expect(RenderUpdates.needs_render(canvas, true, now), "A changed frame renders the canvas")
	expect(not RenderUpdates.needs_render(canvas, false, now), "An unchanged canvas sleeps through a video frame")
	expect(RenderUpdates.needs_render(world, false, now), "Other viewports render every drawn frame")
	expect(RenderUpdates.needs_render(canvas, false, now + RenderUpdates.CHANGES_ONLY_REFRESH_MSEC),
		"A sleeping canvas still refreshes periodically")
	var terminal := SubViewport.new()
	terminal.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	canvas.add_child(terminal)
	expect(RenderUpdates.needs_render(canvas, false, now), "A child rendering every frame keeps the canvas current")
	canvas.free()
	world.free()


func test_before_draw_work_follows_the_change_sample_once() -> void:
	var low_processor := OS.low_processor_usage_mode
	OS.low_processor_usage_mode = true
	var calls: Array[String] = []
	var work := func(): calls.append("work")
	var hook := func(): calls.append("hook")
	RenderUpdates.before_draw(work)
	RenderUpdates.before_draw(work)
	expect(not OS.low_processor_usage_mode, "Queued work draws this iteration without a rendering change")
	RenderUpdates.add_draw_hook(hook)
	RenderUpdates.prepare_frame(false)
	expect(OS.low_processor_usage_mode, "Low-processor mode resumes once that frame draws")
	RenderUpdates.prepare_frame(false)
	RenderUpdates.remove_draw_hook(hook)
	RenderUpdates.prepare_frame(false)
	expect(calls == ["work", "hook", "hook"], "Queued work runs once, then hooks each frame until removed: %s" % [calls])
	OS.low_processor_usage_mode = low_processor


func test_activity_wakes_then_returns_to_idle_rendering() -> void:
	# Given an idle application loop.
	var low_processor := OS.low_processor_usage_mode
	OS.low_processor_usage_mode = true
	# When activity is reported.
	var generation := RenderUpdates.activity()
	expect(not OS.low_processor_usage_mode, "Activity wakes the normal render loop")
	# Then a quiet application returns to low-processor rendering.
	RenderUpdates._finish_activity(generation)
	expect(OS.low_processor_usage_mode, "Quiet activity returns to idle rendering")
	OS.low_processor_usage_mode = low_processor


func test_layered_page_frames_keep_texture_until_frame_pre_draw() -> void:
	var low_processor := OS.low_processor_usage_mode
	OS.low_processor_usage_mode = true
	var chromium := Chromium.new()
	var decoder := Decoder.new()
	var presented := [0]
	chromium.presented.connect(func(): presented[0] += 1)
	chromium.video_decoder = decoder
	chromium.video_codec = "hevc"
	decoder.frames.append(_nv12(64, 48))
	chromium._update_frame()
	var texture: Texture2D = chromium.texture
	expect(chromium.frames == 1 and texture != null, "The first frame creates the page texture at once")
	chromium.present_at_draw = true
	decoder.frames.append(_nv12(64, 48))
	chromium._update_frame()
	expect(chromium.frames == 1 and presented[0] == 1, "A layered page holds a frame that keeps its texture")
	expect(not OS.low_processor_usage_mode, "The held frame still draws this iteration")
	RenderUpdates.prepare_frame(false)
	expect(chromium.frames == 2 and presented[0] == 2 and chromium.texture == texture, "frame_pre_draw presents it in the same texture")
	decoder.frames.append(_nv12(80, 48))
	chromium._update_frame()
	expect(chromium.frames == 3 and chromium.texture != texture, "A new page size replaces the texture at once")
	chromium.present_at_draw = false
	decoder.frames.append(_nv12(80, 48))
	chromium._update_frame()
	expect(chromium.frames == 4, "A page drawn in the canvas presents frames at once")
	chromium.free()
	OS.low_processor_usage_mode = low_processor


func test_page_layer_matches_texture_rect_aspect_fit() -> void:
	expect(Pane.keep_aspect_centered(Vector2(1000, 600), Vector2i(1920, 1080)) == Rect2(0, 19, 1000, 562),
		"A wide page letterboxes with TextureRect's integer height")
	expect(Pane.keep_aspect_centered(Vector2(1000, 600), Vector2i(1080, 1440)) == Rect2(275, 0, 450, 600),
		"A tall page pillarboxes with TextureRect's integer width")
	expect(Pane.keep_aspect_centered(Vector2(999.5, 600.5), Vector2i(1000, 600)) == Rect2(0.25, 0.75, 999, 599),
		"Fractional pane sizes truncate like TextureRect")

func test_render_stats_report_wrapped_texture_bytes_as_unavailable() -> void:
	var stats := preload("res://graffitty/render_stats.gd")
	expect(stats._texture_memory(-29_492_322_048) == "unavailable", "Wrapped Metal texture byte count")
	expect(stats._texture_memory(0) == "0MiB", "A genuine zero remains measurable")
	expect(stats._texture_memory(64 * 1048576) == "64MiB", "Positive memory remains in MiB")
