extends SceneTree
## Real client chooser, every locale, a narrow viewport, and preference reload.
const Service := preload("res://config/Localization.gd")
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	print("PASS " if value else "FAIL ", message)
	if not value: failures.append(message)

func _run() -> void:
	var localization := root.get_node("Localization") as Service
	check(localization.choice == "auto" and not localization.server_controlled(), "First launch uses the client system-language default")
	check(TranslationServer.get_locale() == localization.resolve("auto").replace("-", "_"), "Before connecting, the interface automatically follows the system locale")
	root.size = Vector2i(430, 900)
	root.content_scale_size = Vector2i(430, 900)
	var manager := preload("res://scenes/remote/RemoteManager.gd").new()
	root.add_child(manager)
	root.content_scale_factor = 1.0
	await process_frame
	var selector := manager.chooser.find_child("LanguageSelector", true, false) as OptionButton
	check(selector != null and selector.item_count == 12, "System language and all 11 languages are selectable")
	check(selector.get_item_metadata(selector.selected) == "auto", "The optional language selector starts on automatic")
	manager._new_connection()
	check(manager.dialog.visible and not FileAccess.file_exists(localization.preference_path()), "Adding a server requires no language choice or saved preference")
	for option in manager.stream_options.values():
		check(option.get_selected_id() == 0, "Stream preferences default to Auto")
	manager._load_stream_options({"max_height":720,"fps":30,"bitrate_kbps":5000})
	check(manager.stream_options.max_height.get_selected_id() == 720 and manager.stream_options.fps.get_selected_id() == 30 and manager.stream_options.bitrate_kbps.get_selected_id() == 5000, "Saved stream preferences restore independently")
	manager._cancel_editor()
	for language in localization.locales:
		localization.set_language(language, false)
		await process_frame
		await process_frame
		check(manager.connection_tab.atr("Connection") == localization.catalog.messages["Connection"][language], language + " updates existing controls")
		check(selector.get_item_metadata(selector.selected) == language, language + " updates the selector")
		for source in ["Servers…", "This Computer", "Return to This Computer", "Open in this window", "Open in new window", "Saved servers", "Show servers at startup"]:
			var translated: String = localization.catalog.messages[source].get(language, "")
			check(not translated.is_empty() and str(TranslationServer.translate(source)) == translated, language + " translates " + source)
		check(manager.chooser.content.get_combined_minimum_size().x <= manager.get_viewport_rect().size.x, language + " fits the phone viewport")
		manager._new_connection()
		await process_frame
		check(manager.dialog.content.get_combined_minimum_size().x <= manager.get_viewport_rect().size.x, language + " stream settings fit the phone viewport")
		manager._cancel_editor()
		if language in ["ko", "ja", "de", "fr"] and DisplayServer.get_name() != "headless":
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_LOCALIZATION_TEST_OUTPUT").path_join(language + ".png"))
	localization.set_language("ko")
	manager.entries["fixture"] = {"name": "Settings", "url": "wss://example.invalid", "workspace": "main"}
	manager._set_state("fixture", "disconnected", "Ready to connect")
	manager._refresh_card("fixture")
	check(manager.cards.fixture.heading.atr("Settings") == "Settings", "A server name matching a UI message stays literal")
	var saved := ConfigFile.new()
	check(saved.load(localization.preference_path()) == OK and saved.get_value("localization", "language") == "ko", "Language preference persists on this device")
	localization.set_language("en-US", false)
	localization._ready()
	check(localization.choice == "ko" and TranslationServer.translate("Settings") == "설정", "Saved language is restored on startup")
	manager.queue_free()
	await process_frame
	localization.set_language("ja", false)
	check(not FileAccess.file_exists(preload("res://graffitty/paths.gd").stdpath("config").path_join("remote.json")), "Language choice does not write server settings")
	print("LOCALIZATION_PASS" if failures.is_empty() else "LOCALIZATION_FAIL")
	quit(0 if failures.is_empty() else 1)
