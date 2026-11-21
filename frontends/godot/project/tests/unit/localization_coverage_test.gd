extends "res://tests/unit/test_case.gd"
## Every English source the app or a built-in control shows needs a catalog
## entry. A missing one stays English beside translated text in every language.
const CATALOG := "res://config/localization.json"
## App UI text that stays the same in every language.
const LITERAL := {
	"Graffitty": "product name",
	"graffitty-2fa": "default authenticator profile",
	"30m": "duration syntax example",
	"30s, 5m, 1h": "duration syntax examples",
	"Group %d": "menu separator id, never shown",
}
## Key names, PID, RAM and dictation provider brand names are invariant.
## #procs intentionally stays compact and identical in every locale (including
## Korean); its tooltip is translated.
const SAME_IN_EVERY_LANGUAGE := ["Alt", "Tab", "PID", "RAM", "#procs", "Gemini", "OpenAI"]
## Built-in labels that are color channels or models, or that the engine
## composes from catalog text ("All Files" + " (*.*)").
const ENGINE_LITERAL := ["#", "A", "B", "G", "R", "I", "HSV", "RGB", "OKHSL", "All Files (*.*)"]
## Built-in text a headless walk cannot reach: platform-specific items, and
## dialogs or menus that the engine fills only when they open.
const ENGINE_ON_DEMAND := [
	"Emoji & Symbols", "Pick a color from the screen.", "Pick a color from the application window.",
	"Color: %s\nLMB: Apply color", "Color: %s\nLMB: Apply color\nRMB: Remove preset",
	"The changes to this palette have not been saved to a file.",
	"Load Color Palette", "Save Color Palette", "All Files", "All Recognized",
	"File \"%s\" already exists.\nDo you want to overwrite it?",
	"You don't have permission to access contents of this folder.",
	"Copy Path", "Delete", "New Folder...", "Refresh", "Show Package Contents", "Network",
	"Open in Finder", "Show in Finder", "Open in File Explorer", "Show in File Explorer",
	"Open in File Manager", "Show in File Manager",
]
## A string literal right after one of these is shown as UI text.
const SINKS := [
	r"\b(?:tr|atr)\(",
	r"\bTranslationServer\.translate\(",
	r"\.text\(\s*[\w.]+\s*,", # Localization.text(target, source, ...)
	r"(?<!\w)(?:text|tooltip_text|placeholder_text|title|dialog_text|ok_button_text|cancel_button_text)\s*\+?=(?!=)",
	r"\badd_(?:item|check_item|radio_check_item|submenu_item|submenu_node_item|button|cancel_button|tab)\(",
	r"\badd_icon_(?:item|check_item|radio_check_item)\([^,\n]+,",
	r"\bset_(?:item_text|item_tooltip|tab_title|tab_tooltip)\([^,\n]+,",
	r"""["'](?:label|title|tooltip)["']\s*:""",
	# Project helpers whose message becomes status, notification or dialog text.
	r"\b(?:set_status|_set_state|_auth_error|_connection_error|_network_failed|_error|_fail|_complete)\(",
	r"""\b_set_state\(\s*\w+\s*,\s*"[^"\n]*"\s*,""",
	r"\bshow_result\(\s*\w+\s*,",
]
const STRING := r"""(?:"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)')"""
## "Menu::Item" labels are translated one component at a time.
const MENU_PATH := r"""["']([A-Z][^"'\n:]*(?:::[^"'\n:]+)+)(?:::)?["']"""
const SCENE_TEXT := r"""(?m)^(?:text|tooltip_text|placeholder_text|title|dialog_text|ok_button_text|cancel_button_text) = "((?:[^"\\]|\\.)*)["]"""
var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOG)).messages
var format := RegEx.create_from_string(r"%[0-9.]*[sdf]|%%")
var letter := RegEx.create_from_string(r"[A-Za-z]")
var control := RegEx.create_from_string(r"[\x00-\x08\x0b-\x1f]")
var unicode := RegEx.create_from_string(r"\\u([0-9a-fA-F]{4})")
var token := RegEx.create_from_string(r"""(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|#)""")
var missing := {}
var literal_used := {}


func test_app_ui_text_has_catalog_entries() -> void:
	var sink := RegEx.create_from_string("(?:" + "|".join(PackedStringArray(SINKS)) + r")\s*" + STRING)
	var menu := RegEx.create_from_string(MENU_PATH)
	for directory in ["res://scenes", "res://config", "res://graffitty"]:
		for path in files_under(directory, ".gd"):
			var code := without_comments(FileAccess.get_file_as_string(path))
			for found in sink.search_all(code):
				var group := 1 if found.get_start(1) >= 0 else 2
				check(unescape(found.get_string(group)), path, code, found.get_start())
			for found in menu.search_all(code):
				check(found.get_string(1), path, code, found.get_start())
	var scene_text := RegEx.create_from_string(SCENE_TEXT)
	for path in files_under("res://scenes", ".tscn"):
		var scene := FileAccess.get_file_as_string(path)
		for found in scene_text.search_all(scene):
			check(unescape(found.get_string(1)), path, scene, found.get_start())
	expect(missing.is_empty(), "Add these UI strings to %s, or to LITERAL if they never change:\n%s" % [CATALOG, "\n".join(PackedStringArray(missing.keys()))])
	for text in LITERAL:
		expect(literal_used.has(text), "LITERAL entry is no longer shown: " + text)


func test_builtin_control_text_has_catalog_entries() -> void:
	var line := LineEdit.new()
	var editor := TextEdit.new()
	var rich := RichTextLabel.new()
	var picker := ColorPicker.new()
	var windows: Array[Window] = [AcceptDialog.new(), ConfirmationDialog.new()]
	for mode in [FileDialog.FILE_MODE_OPEN_FILE, FileDialog.FILE_MODE_SAVE_FILE]:
		var files := FileDialog.new()
		files.access = FileDialog.ACCESS_RESOURCES
		files.file_mode = mode
		windows.append(files)
	var roots: Array[Node] = [line.get_menu(), editor.get_menu(), rich.get_menu(), picker]
	for button in picker.find_children("*", "MenuButton", true, false):
		button.about_to_popup.emit() # Mode and shape menus fill when opened.
		roots.append(button.get_popup())
	roots.append_array(windows)
	var shown := {}
	for root in roots:
		collect(root, shown)
	for text in shown:
		if text in ENGINE_LITERAL: continue
		expect(catalog.has(text), "%s shows text without a catalog entry: %s" % [shown[text], text])
	for text in ENGINE_LITERAL:
		expect(shown.has(text), "ENGINE_LITERAL entry is no longer shown: " + text)
	for text in ENGINE_ON_DEMAND:
		expect(catalog.has(text), "Built-in text needs a catalog entry: " + text)
	for node in [line, editor, rich, picker] + windows:
		node.free()


func test_every_entry_is_translated() -> void:
	var locales: Array = JSON.parse_string(FileAccess.get_file_as_string(CATALOG)).locales.keys()
	locales.erase("en-US")
	for source in catalog:
		if source in SAME_IN_EVERY_LANGUAGE: continue
		expect(locales.any(func(locale): return catalog[source][locale] != source), "Every language copies the English source: " + source)


func check(text: String, path: String, source: String, offset: int) -> void:
	if "::" in text:
		for part in text.split("::", false):
			check(part, path, source, offset)
		return
	# URLs, terminal escape sequences and pure format strings are not words.
	if "://" in text or control.search(text) != null or letter.search(format.sub(text, "", true)) == null: return
	if LITERAL.has(text):
		literal_used[text] = true
	elif not catalog.has(text):
		missing["%s:%d: %s" % [path, source.substr(0, offset).count("\n") + 1, text.c_escape()]] = true


func unescape(literal: String) -> String:
	for found in unicode.search_all(literal):
		literal = literal.replace(found.get_string(), char(found.get_string(1).hex_to_int()))
	return literal.c_unescape()


func collect(node: Node, shown: Dictionary) -> void:
	var texts: Array[String] = []
	if node is PopupMenu:
		for index in node.item_count:
			texts.append_array([node.get_item_text(index), node.get_item_tooltip(index)])
	if node is Window: texts.append(node.title)
	if node is AcceptDialog: texts.append(node.dialog_text)
	if node is Control: texts.append(node.tooltip_text)
	if node is Button or node is Label: texts.append(node.text)
	if node is LineEdit or node is TextEdit: texts.append(node.placeholder_text)
	for text in texts:
		if not text.strip_edges().is_empty(): shown[text] = node.get_class()
	for child in node.get_children(true):
		collect(child, shown)


## Comments may quote UI text, for example while documenting a menu path.
func without_comments(code: String) -> String:
	var lines := code.split("\n")
	for index in lines.size():
		if not "#" in lines[index]: continue
		for found in token.search_all(lines[index]):
			if found.get_string() == "#":
				lines[index] = lines[index].left(found.get_start())
				break
	return "\n".join(lines)


func files_under(directory: String, extension: String) -> Array[String]:
	var found: Array[String] = []
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(extension): found.append(directory.path_join(file))
	for sub in DirAccess.get_directories_at(directory):
		found.append_array(files_under(directory.path_join(sub), extension))
	return found
