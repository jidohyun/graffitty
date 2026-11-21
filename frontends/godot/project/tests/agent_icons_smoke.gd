extends SceneTree
## Real GPU pixels for the mod painter and native fallback badge.
const Badge := preload("res://scenes/AgentStatusBadge.gd")
var failures := 0

func _initialize() -> void:
	load(ProjectSettings.globalize_path("res://../../../tests/llm-e2e/replay/background.gd")).install(self)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1

func pixels(image: Image, rect: Rect2i) -> Dictionary:
	var colored := 0
	var alpha := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var pixel := image.get_pixel(x, y)
			alpha += pixel.a
			if pixel.a > 0.1 and maxf(pixel.r, maxf(pixel.g, pixel.b)) - minf(pixel.r, minf(pixel.g, pixel.b)) > 0.04:
				colored += 1
	return {"colored": colored, "alpha": alpha}

func run() -> void:
	var host: RefCounted = ClassDB.instantiate("ModHost")
	check(host.setup("").is_empty(), "Mod host starts")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var view: Control = ClassDB.instantiate("ModView")
	viewport.add_child(view)
	view.size = Vector2(64, 64)
	view.set_asset_roots(PackedStringArray(["res://assets/icons"]))
	check(view.load_source("agent-icon-pixels", """
import { View, image } from 'graffitty-ui';
import { props } from 'graffitty';
export default class extends View {
  render() { return image(props().file).size(64).when(props().offline, icon => icon.grayscale().opacity(0.55)); }
}
""", '{}').is_empty(), "Pixel fixture loads")
	var badge := Badge.new()
	viewport.add_child(badge)
	badge.position = Vector2(0, 80)
	for provider in ["pi", "codex"]:
		var live_alpha := 0.0
		for status in ["busy", "offline", "idle"]:
			var offline: bool = status == "offline"
			view.set_props(JSON.stringify({"file": "pi.svg" if provider == "pi" else "codex.png", "offline": offline}))
			badge.set_agent(provider, status)
			view.render_now()
			for _frame in range(3): await process_frame
			RenderingServer.force_draw(false)
			var capture := viewport.get_texture().get_image()
			var mod_pixels := pixels(capture, Rect2i(0, 0, 64, 64))
			var native_pixels := pixels(capture, Rect2i(badge.logo.global_position, badge.logo.size))
			check(mod_pixels.alpha > 10 and native_pixels.alpha > 2, provider + " " + status + " icons are visible")
			if offline:
				check(mod_pixels.colored == 0 and native_pixels.colored == 0, provider + " offline icons are grayscale in both renderers")
				check(absf(mod_pixels.alpha / live_alpha - 0.55) < 0.02, provider + " offline artwork dims without changing its shape")
			elif provider == "pi":
				check(mod_pixels.colored > 100 and native_pixels.colored > 5, "Pi keeps its original colors when " + status)
			if status == "busy": live_alpha = mod_pixels.alpha
			var evidence := OS.get_environment("GRAFFITTY_ICON_EVIDENCE")
			if not evidence.is_empty(): capture.save_png(evidence.path_join(provider + "-" + status + ".png"))
	viewport.queue_free()
	await create_timer(0.3).timeout
	print("AGENT_ICONS_PASS" if failures == 0 else "AGENT_ICONS_FAIL")
	quit(0 if failures == 0 else 1)
