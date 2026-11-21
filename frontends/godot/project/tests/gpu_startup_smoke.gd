extends SceneTree
## Run headless to verify startup registration and unaccelerated capability checks.

func _initialize() -> void:
	_check.call_deferred()

func _check() -> void:
	var guard := root.get_node_or_null("GpuStartup")
	var browser := preload("res://scenes/ChromiumGpuStream.gd").new()
	var assets := preload("res://scenes/TerminalGpuAssets.gd").new()
	var localization := root.get_node("Localization")
	var notice: Dictionary = localization.catalog.messages.get(preload("res://graffitty/GpuStartup.gd").NOTICE, {})
	if guard == null or guard.get_index() >= localization.get_index():
		push_error("GPU startup guard must precede localization")
		quit(1)
		return
	var settings := ProjectSettings
	if settings.get_setting_with_override_and_custom_features("rendering/rendering_device/fallback_to_d3d12", ["windows"]) != false or not settings.get_setting("rendering/rendering_device/fallback_to_opengl3") or not settings.get_setting("rendering/rendering_device/fallback_to_vulkan"):
		push_error("Windows renderer settings must prevent D3D12 re-entry and allow forward fallback")
		quit(1)
		return
	for source in ["Graphics startup failed", "Diagnostic log", "No startup progress", "Graphics driver initialization failed", "Graphics device lost", "Early exit (cause unknown)"]:
		for language in localization.locales:
			if str(localization.catalog.messages.get(source, {}).get(language, "")).is_empty():
				push_error("Missing startup diagnostic translation for " + language)
				quit(1)
				return
	for language in localization.locales:
		if str(notice.get(language, "")).count("%s") != 1:
			push_error("Missing renderer in GPU notification for " + language)
			quit(1)
			return
	if browser.start_shared(OS.get_process_id()) or assets.start(OS.get_process_id()):
		push_error("Shared GPU resources advertised without a rendering device")
		quit(1)
		return
	print("PASS Windows fallback settings, first autoload, localized startup diagnostics, unaccelerated browser and terminal capabilities")
	quit()
