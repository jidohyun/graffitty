extends SceneTree
const Service := preload("res://scenes/AppNotifications.gd")
const Overlay := preload("res://scenes/NotificationOverlay.gd")
var failures: Array[String] = []

class Host extends Node:
	var application: Dictionary
	var pane_focus := "%1"
	func focus_pane(_key: String) -> void: pass

func _initialize() -> void: _run.call_deferred()

# A localized notice whose argument must stay literal.
func notice(service: Node, owner: Node, path: String, event_id := "") -> Dictionary:
	var source := "Server font download failed: %s"
	return service.post(tr("Rename Pane"), tr(source) % path, owner, "info", 12.0, event_id,
		{"title": "Rename Pane", "body": source, "args": [path]})

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures.append(message)

func snapshot(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_NOTIFICATION_EVIDENCE").path_join(name + ".png"))

func _run() -> void:
	root.size = Vector2i(430, 900)
	root.content_scale_size = Vector2i(430, 900)
	root.content_scale_factor = 1
	var service := Service.new()
	root.add_child(service)
	var host := Host.new()
	host.application = {"notifications": service}
	root.add_child(host)
	var input := LineEdit.new()
	input.position = Vector2(20, 650)
	input.size = Vector2(250, 40)
	root.add_child(input)
	input.grab_focus()
	var overlay := Overlay.new()
	overlay.host = host
	host.add_child(overlay)
	var language := root.get_node("Localization")
	for locale in language.locales:
		language.set_language(locale, false)
		notice(service, host, "~/.config/graffitty/fonts")
		check(overlay.cards[0].modulate.a == 0, locale + " starts transparent")
		# Step the real tween deterministically; cold GPU compilation can make
		# the first rendered frame longer than the complete entrance animation.
		overlay.cards[0].animation.pause()
		overlay.cards[0].animation.custom_step(0.1)
		check(overlay.cards[0].modulate.a > 0 and overlay.cards[0].modulate.a < 1, locale + " fades through intermediate opacity")
		overlay.cards[0].animation.play()
		await create_timer(0.3).timeout
		check(input.has_focus(), locale + " toast leaves typing focus alone")
		check(root.get_visible_rect().encloses(overlay.cards[0].get_global_rect()), locale + " toast fits phone viewport")
		if locale == "en-US": snapshot("phone-notification")
		overlay.open_history()
		await process_frame
		await process_frame
		check(overlay.history_open() and overlay.history_panel.is_visible_in_tree(), locale + " history opens in its dockable window")
		check(overlay.history_list.get_child_count() == 1, locale + " history includes its notice")
		if locale == "en-US": snapshot("phone-history")
		overlay.close_history()
		service.clear_history()
		await create_timer(0.3).timeout
		input.grab_focus()
	# Both a visible toast and its already-open history keep source messages,
	# so switching servers translates them without touching the supplied path.
	language.set_language("en-US", false)
	var literal_path := "~/.config/Settings %s [b]/fonts"
	notice(service, host, literal_path)
	overlay.open_history()
	for locale in ["ko", "ja"]:
		language.set_language(locale, false)
		await process_frame
		var toast = overlay.cards[0]
		var history = overlay.history_list.get_child(0)
		check(toast.title.text == tr("Rename Pane") and toast.title.text != "Rename Pane", locale + " updates the visible toast title")
		check(history.title.text == toast.title.text and history.body.text == toast.body.text, locale + " updates existing history and toast together")
		check(toast.body.text.ends_with(literal_path) and not toast.body.text.contains("download failed"), locale + " translates the body while preserving the literal path")
	overlay.close_history()
	service.clear_history()
	await create_timer(0.3).timeout
	language.set_language("en-US", false)
	for index in 5: service.post("Notice %d" % index, "Queued notices keep their history.", host)
	await create_timer(0.4).timeout
	check(overlay.cards.size() == 3 and overlay.queue.size() == 2, "A burst queues excess cards without losing history")
	root.size = Vector2i(430, 350)
	root.content_scale_size = Vector2i(430, 350)
	await create_timer(0.3).timeout
	check(overlay.cards.size() == 1 and overlay.queue.size() == 4, "A smaller viewport queues cards instead of clipping the stack")
	service.clear_history()
	await create_timer(0.3).timeout
	check(overlay.cards.is_empty() and overlay.queue.is_empty(), "Clear dismisses active and queued cards")
	host.queue_free()
	service.queue_free()
	input.queue_free()
	await process_frame
	print("NOTIFICATIONS_PASS" if failures.is_empty() else "NOTIFICATIONS_FAIL")
	quit(0 if failures.is_empty() else 1)
