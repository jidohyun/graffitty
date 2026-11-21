extends "res://tests/unit/test_case.gd"
const Service := preload("res://config/Localization.gd")

func test_language_selector_shapes_autonyms_in_their_own_locale() -> void:
	var service := Service.new()
	var previous := TranslationServer.get_locale()
	service.set_language("ko", false)
	var selector := service.selector()
	for index in range(1, selector.item_count):
		var language: String = selector.get_item_metadata(index)
		expect(selector.get_popup().get_item_language(index) == language.replace("-", "_"),
			"Autonym selects its own font fallback before choosing " + language)
	service.set_language("fr", false)
	var japanese := service.locales.keys().find("ja") + 1
	expect(selector.get_item_text(japanese) == "日本語", "Japanese autonym stays literal in French UI")
	expect(selector.get_popup().get_item_language(japanese) == "ja", "Changing UI language preserves Japanese shaping")
	selector.free()
	for translation in service.translations: TranslationServer.remove_translation(translation)
	service.free()
	TranslationServer.set_locale(previous)

func test_catalog_locales_and_format_arguments() -> void:
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Service.CATALOG))
	var locales := ["en-US", "fr", "pt-BR", "es", "it", "ko", "ja", "de", "nb", "sv", "da"]
	expect(catalog.locales.keys() == locales, "All requested languages use standard locale codes")
	var format := RegEx.new()
	format.compile("%(?:[0-9.]*[sdf]|%)")
	for source in catalog.messages:
		var messages: Dictionary = catalog.messages[source]
		expect(messages.keys() == locales, "Every language is beside its source: " + source)
		expect(messages["en-US"] == source, "English fallback matches the source: " + source)
		var slots := format.search_all(source).map(func(item): return item.get_string())
		for language in locales:
			expect(not str(messages[language]).is_empty(), language + " is not empty: " + source)
			expect(format.search_all(messages[language]).map(func(item): return item.get_string()) == slots, language + " preserves formatting arguments: " + source)

func test_locale_selection_fallback_and_formatted_text() -> void:
	var service := Service.new()
	var previous := TranslationServer.get_locale()
	expect(service.resolve("fr_CA") == "fr", "Regional variants use the supported language")
	expect(service.resolve("pt_BR") == "pt-BR", "Brazilian Portuguese uses the requested locale")
	expect(service.resolve("ja_JP") == "ja", "Japanese uses ja")
	expect(service.resolve("no_NO") == "nb", "Norwegian uses Bokmål")
	expect(service.resolve("zz_ZZ") == "en-US", "Unsupported languages fall back to English")
	var label := Label.new()
	service.set_language("ko", false)
	service.text(label, "Dictation → %s", ["%12 Settings"])
	expect(label.text == "받아쓰기 → %12 Settings", "Translate the message, never its supplied pane name")
	service.set_language("ja", false)
	expect(label.text == "音声入力 → %12 Settings", "Open formatted text updates on language change")
	expect(TranslationServer.translate("Unknown diagnostic") == "Unknown diagnostic", "Unknown messages stay readable")
	label.text = "A newer status"
	service.set_language("fr", false)
	expect(label.text == "A newer status", "An old binding must not overwrite newer text")
	label.free()
	service.set_language("de", false) # Also prunes released controls safely.
	for translation in service.translations: TranslationServer.remove_translation(translation)
	service.free()
	TranslationServer.set_locale(previous)

func test_language_config_remains_a_client_fallback() -> void:
	var args := PackedStringArray([client_toml("language", "language = \"ko\"\n")])
	expect(preload("res://config/UserConfig.gd").language(args) == "ko", "client.toml supplies the client language")

func test_graph_status_translates_failure_and_preserves_provider_details() -> void:
	var service := Service.new()
	var previous := TranslationServer.get_locale()
	service.set_language("ko", false)
	var inspector := preload("res://scenes/GraphQueueInspector.gd")
	var row := {"status": "failed: Graph run message limit reached", "pending": false}
	expect(inspector.status_text(row) == "[!] 실패: 그래프 실행 메시지 한도에 도달함", "Built-in failure reasons translate with their prefix")
	row.status = "cancel failed: Provider %s [b] detail"
	expect(inspector.status_text(row) == "[!] 취소 실패: Provider %s [b] detail", "Unknown provider details stay literal")
	for translation in service.translations: TranslationServer.remove_translation(translation)
	service.free()
	TranslationServer.set_locale(previous)

func test_builtin_pane_titles_translate_without_changing_custom_names() -> void:
	var service := Service.new()
	var previous := TranslationServer.get_locale()
	var model := preload("res://scenes/TerminalSession.gd").new()
	service.set_language("ko", false)
	model.builtin_title = "Filetree"
	expect(model.title == "파일 트리", "Built-in filetree title is translated on the client")
	model.builtin_title = "File viewer"
	expect(model.title == "파일 뷰어", "Built-in viewer title is translated")
	model.pin_title("Filetree")
	service.set_language("ja", false)
	expect(model.title == "Filetree", "A user-assigned title remains literal even when it matches a source message")
	model.pin_title("")
	expect(model.title == "ファイルビューアー", "Clearing the custom name restores the localized built-in title")
	model.builtin_title = ""
	model._on_title("Filetree")
	expect(model.title == "Filetree", "Program-reported titles are never translated")
	model.free()
	for translation in service.translations: TranslationServer.remove_translation(translation)
	service.free()
	TranslationServer.set_locale(previous)

func test_server_language_does_not_override_device_preference() -> void:
	var service = preload("res://config/Localization.gd").new()
	var previous := TranslationServer.get_locale()
	var first := Node.new()
	var second := Node.new()
	service.set_language("fr", false)
	service.set_server_language(first, "ko")
	service.set_server_language(second, "ja")
	service.follow_server(second)
	expect(service.choice == "fr" and not service.server_controlled(), "Connecting and focusing servers preserves client language")
	service.set_language("de", false)
	service.remove_server(second)
	expect(service.choice == "de", "Client can change language while connected")
	first.free()
	second.free()
	# Later tests assert English source text.
	for translation in service.translations: TranslationServer.remove_translation(translation)
	service.free()
	TranslationServer.set_locale(previous)
