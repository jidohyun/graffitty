extends "res://tests/unit/test_case.gd"
const Config := preload("res://graffitty/config.gd")
const PanelScript := preload("res://scenes/mods/PanelWindow.gd")

class BlurProbe extends "res://scenes/DesktopBlur.gd":
	var calls: Array = []
	var supported := true
	func _apply_native(_window: Window, enabled: bool, material: int) -> bool:
		calls.append({"enabled": enabled, "material": material})
		return supported

func test_mod_blur_respects_both_preferences_and_removes_disabled_backdrop() -> void:
	var blur := BlurProbe.new()
	var window := Window.new()
	blur.settings = Config.WindowSettings.new()
	blur.settings.background_blur = true
	blur.apply_to(window, true)
	expect(not blur.calls.back().enabled, "An opaque native window clears the backdrop even with blur enabled")
	window.transparent = true
	blur.apply_to(window, true)
	expect(blur.calls.back().enabled, "A translucent opted-in mod follows enabled user blur")
	blur.apply_to(window, false)
	expect(not blur.calls.back().enabled, "Opting out explicitly removes previous native blur")
	blur.settings.background_blur = false
	blur.apply_to(window, true)
	expect(not blur.calls.back().enabled, "A mod cannot override the user's disabled preference")
	blur.settings.background_blur = true
	blur.supported = false
	expect(not blur.apply_to(window, true), "Unsupported compositor reports no blur, without requiring a fallback")
	window.free()
	blur.free()

func test_all_builtin_panels_request_visible_blur() -> void:
	var registry := preload("res://scenes/mods/ModService.gd").registry()
	for name in registry:
		var manifest: Dictionary = registry[name]
		if manifest.get("host", "panel") not in ["panel", "bar"]: continue
		expect(manifest.get("background_blur") == true, name + " explicitly enables blur")
		var opacity: float = manifest.get("background_opacity", 1.0)
		expect(opacity > 0.0 and opacity < 1.0, name + " has a translucent background")
	var status_source := FileAccess.get_file_as_string("res://mods/status-line/main.js")
	expect(not status_source.contains(".bg(t.chrome)"), "Status line leaves its panel backdrop visible")

func test_renderer_blur_radius_validation() -> void:
	for value in [0, 0.5, 12, 64.0]:
		expect(PanelScript.valid_blur_radius(value), "Accept finite radius " + str(value))
	for value in [-1, 65, INF, NAN, "12", true, null]:
		expect(not PanelScript.valid_blur_radius(value), "Reject invalid radius " + str(value))

func test_docked_blur_material_and_disable() -> void:
	var panel := PanelScript.new()
	panel.background_opacity = 0.8
	panel.force_native = false
	panel._desktop = PanelContainer.new()
	panel.apply_background()
	expect(panel._desktop.material is ShaderMaterial, "Dock surface uses renderer blur")
	expect(panel._desktop.material.get_shader_parameter("radius") == 12.0, "Default blur radius is 12 logical pixels")
	panel.background_blur_radius = 24.0
	panel.apply_background()
	expect(panel._desktop.material.get_shader_parameter("radius") == 24.0, "Radius is configurable")
	panel.background_blur_radius = 0.0
	panel.apply_background()
	expect(panel._desktop.material == null, "Zero radius removes shader")
	panel.background_blur_radius = 12.0
	panel.background_blur = false
	panel.apply_background()
	expect(panel._desktop.material == null, "Mod opt-out removes shader")
	panel.background_blur = true
	panel.background_opacity = 1.0
	panel.apply_background()
	expect(panel._desktop.material == null, "Opaque panels skip unnecessary blur")
	panel._desktop.free()
	panel.free()

func test_mod_blur_defaults_to_following_user_preference() -> void:
	var panel := PanelScript.new()
	expect(panel.background_blur, "Existing translucent mod manifests follow native blur by default")
	panel.background_blur = false
	expect(not panel.background_blur, "A panel may explicitly opt out")
	panel.free()
