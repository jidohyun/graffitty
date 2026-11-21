extends SceneTree
## Footer actions stay compact and readable after translation, folding and IME resizing.
var failures := 0

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("connection-page-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func settle() -> void:
	for i in 6: await process_frame

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(820, 910)
	root.add_child(viewport)
	var page := preload("res://scenes/remote/ConnectionPage.gd").new()
	page.title = "Edit server"
	page.ok_button_text = "Save and connect"
	viewport.add_child(page)
	# Force a scrolling form without needing saved servers or credentials.
	var form := Control.new()
	form.custom_minimum_size.y = 1100
	page.body.add_child(form)
	var localization := root.get_node("Localization")
	for language in ["fr", "de", "en-US"]:
		localization.set_language(language, false)
		for extent in [Vector2i(820, 910), Vector2i(360, 780), Vector2i(780, 360), Vector2i(360, 280), Vector2i(820, 910)]:
			viewport.size = extent
			await settle()
			var label := "%s %s" % [language, extent]
			check(page.primary.size.y >= 48 and page.primary.size.y <= 72, label + ": primary action keeps a compact touch target")
			var back_text: String = page.back.tr(page.back.text)
			var font := page.back.get_theme_font("font")
			var text_width := font.get_string_size(back_text, HORIZONTAL_ALIGNMENT_LEFT, -1, page.back.get_theme_font_size("font_size")).x
			var margins := page.back.get_theme_stylebox("normal").get_minimum_size().x
			check(page.back.size.x >= text_width + margins, label + ": Back has room for its full translated label")
			var bounds := Rect2(Vector2.ZERO, Vector2(extent))
			check(bounds.encloses(page.primary.get_global_rect()) and bounds.encloses(page.back.get_global_rect()), label + ": both actions stay on screen")
			check(page.scroll.size.y >= extent.y - 110, label + ": footer leaves the form usable above the keyboard")
	viewport.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
