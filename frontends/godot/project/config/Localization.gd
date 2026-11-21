extends Node
## UI language is a device preference, independent of connected servers.
signal changed
const CATALOG := "res://config/localization.json"
const Paths := preload("res://graffitty/paths.gd")
var locales: Dictionary = {}
var choice := "auto"
var local_choice := "auto"
var _applied := false
var catalog: Dictionary = {}
var translations: Array[Translation] = []
var _formatted: Dictionary = {}

func _init() -> void:
	catalog = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	locales = catalog.get("locales", {})
	for language in locales:
		var translation := Translation.new()
		translation.locale = language.replace("-", "_")
		for source in catalog.get("messages", {}):
			var text: String = catalog.messages[source].get(language, source)
			translation.add_message(source, text if not text.is_empty() else source)
		translations.append(translation)
		TranslationServer.add_translation(translation)

func _ready() -> void:
	if OS.has_feature("android"): _install_android_ui_fallback()
	var language := preload("res://config/UserConfig.gd").language(OS.get_cmdline_user_args())
	var saved := ConfigFile.new()
	if saved.load(preference_path()) == OK:
		language = str(saved.get_value("localization", "language", language))
	set_language(language, false)

static func _install_android_ui_fallback() -> void:
	# Some Android font providers omit the Japanese TTC from automatic fallback,
	# even with a ja language tag.
	#
	# Explicitly attach an available system face to the UI font (not the server's
	# terminal fonts); no font download is needed.
	var base: Font = ThemeDB.get_default_theme().default_font
	if base == null: base = ThemeDB.fallback_font
	if base == null or base.has_meta("android_cjk_fallback"): return
	var paths := PackedStringArray(["/system/fonts/NotoSansCJK-Regular.ttc"])
	paths.append_array(OS.get_system_font_path_for_text("sans-serif", "日本語", "ja", "Jpan"))
	for path in paths:
		if not FileAccess.file_exists(path): continue
		var face := FontFile.new()
		if face.load_dynamic_font(path) != OK or not face.has_char("日".unicode_at(0)): continue
		var fallbacks := base.fallbacks
		fallbacks.append(face)
		base.fallbacks = fallbacks
		base.set_meta("android_cjk_fallback", true)
		return

static func preference_path() -> String:
	return Paths.stdpath("config").path_join("language.conf")

func resolve(language: String) -> String:
	var normalized := language.replace("_", "-").to_lower()
	if normalized == "auto": normalized = OS.get_locale().replace("_", "-").to_lower()
	if normalized in ["jp", "jp-jp"]: normalized = "ja"
	if normalized == "no" or normalized.begins_with("no-"): normalized = "nb"
	for supported in locales:
		if supported.to_lower() == normalized: return supported
	var base := normalized.split("-")[0]
	for supported in locales:
		if supported.to_lower().split("-")[0] == base: return supported
	return "en-US"

func set_language(language: String, persist := true) -> Error:
	var next := "auto" if language == "auto" else resolve(language)
	if persist:
		var config := ConfigFile.new()
		config.set_value("localization", "language", next)
		var error := DirAccess.make_dir_recursive_absolute(preference_path().get_base_dir())
		if error != OK: return error
		error = config.save(preference_path())
		if error != OK: return error
	local_choice = next
	_apply_language()
	return OK

func set_server_language(_source: Object, _language: String) -> void:
	pass

func follow_server(_source: Object) -> void:
	pass

func remove_server(_source: Object) -> void:
	pass

func server_controlled() -> bool:
	return false

func _apply_language() -> void:
	if _applied and choice == local_choice: return
	_applied = true
	choice = local_choice
	TranslationServer.set_locale(resolve(choice).replace("-", "_"))
	# Formatting happens after lookup, so paths, names and provider values stay
	# literal. Retain the source to refresh an already open status or dialog.
	for id in _formatted.keys():
		var binding: Dictionary = _formatted[id]
		var target: Object = binding.target.get_ref()
		if target == null or target.get(binding.property) != binding.rendered:
			_formatted.erase(id)
			continue
		binding.rendered = _render(binding.source, binding.args, binding.translate_args)
		target.set(binding.property, binding.rendered)
	changed.emit()

func _render(source: String, args: Array, translate_args := false) -> String:
	var translated := String(TranslationServer.translate(source))
	if translate_args:
		# Status details such as "Server unreachable" are messages themselves.
		args = args.map(func(arg): return String(TranslationServer.translate(arg)) if arg is String else arg)
	return translated if args.is_empty() else translated % args

## `translate_args` is for arguments that are themselves catalog messages, never
## names or paths: those must stay literal even when they match a message.
func text(target: Object, source: String, args: Array = [], property: StringName = &"text", translate_args := false) -> void:
	var rendered := _render(source, args, translate_args)
	var id := "%d:%s" % [target.get_instance_id(), property]
	_formatted[id] = {"target": weakref(target), "property": property, "source": source, "args": args.duplicate(), "rendered": rendered, "translate_args": translate_args}
	target.set(property, rendered)

func selector() -> OptionButton:
	var button := OptionButton.new()
	button.name = "LanguageSelector"
	button.custom_minimum_size.y = 48
	button.fit_to_longest_item = false
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.add_item(tr("Automatic (system language)"))
	button.set_item_metadata(0, "auto")
	for language in locales:
		button.add_item(locales[language])
		button.set_item_metadata(button.item_count - 1, language)
		# Each autonym needs its own shaping/fallback locale. Android may only
		# expose the Japanese CJK face when the text is explicitly tagged ja.
		button.get_popup().set_item_language(button.item_count - 1, language.replace("-", "_"))
	# Autonyms remain readable even after choosing an unfamiliar language.
	button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var update := func():
		button.set_item_text(0, tr("Automatic (system language)"))
		button.disabled = server_controlled()
		button.tooltip_text = tr("Language is configured by the server.") if server_controlled() else ""
		for index in button.item_count:
			if button.get_item_metadata(index) == choice: button.select(index)
	update.call()
	changed.connect(update)
	button.tree_exiting.connect(func(): changed.disconnect(update))
	button.item_selected.connect(func(index):
		if set_language(button.get_item_metadata(index)) != OK:
			button.tooltip_text = tr("Could not save language preference.")
			update.call())
	return button

func menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var options := {"auto": "Automatic (system language)"}
	options.merge(locales)
	for language in options:
		entries.append({"label": "View::Language::" + options[language],
			"action": func(_host):
				if set_language(language) != OK: push_warning("Could not save language preference."),
			"checked": func(_host): return choice == language,
			"enabled": func(_host): return not server_controlled()})
	return entries
