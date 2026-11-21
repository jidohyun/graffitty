extends "res://tests/unit/test_case.gd"

func test_dummy_renderer_does_not_offer_native_chromium_import() -> void:
	if RenderingServer.get_rendering_device() != null:
		return
	var stream := preload("res://scenes/ChromiumGpuStream.gd").new()
	expect(not stream.start_shared(OS.get_process_id()), "A headless client must stay on video without a rendering device")
	expect(stream.receiver == null and stream.endpoint.is_empty(), "Reject before creating a native receiver or offering an endpoint")
