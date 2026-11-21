extends RefCounted
## Build metadata stays available in packs without Git, Python, or uv.


static func read_metadata(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return { }
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else { }


static func report() -> String:
	var app := read_metadata("res://graffitty/build-info.json")
	var engine := Engine.get_version_info()
	var host := preload("res://graffitty/executables.gd").chromium()
	var chromium: Dictionary = { }
	if not host.is_empty():
		var metadata := host.get_base_dir().path_join("build-info.json")
		if OS.get_name() == "macOS":
			metadata = host.get_base_dir().path_join("../Resources/build-info.json").simplify_path()
		chromium = read_metadata(metadata)
	var unknown := String(TranslationServer.translate("Unknown"))
	# Phones and tablets bundle no Chromium: their pages run in the connected
	# computer's Chromium and arrive as video.
	if OS.has_feature("mobile"):
		return String(TranslationServer.translate("Graffitty: %s\nGit revision: %s\n\nGodot: %s\nGodot revision: %s\n\nChromium: %s\n\nPlatform: %s (%s)")) % [
			app.get("version", String(TranslationServer.translate("Unknown (build metadata unavailable)"))),
			app.get("full_revisionid", unknown),
			engine.string,
			engine.get("hash", unknown),
			String(TranslationServer.translate("Not included (runs on the connected computer)")),
			OS.get_name(),
			Engine.get_architecture_name(),
		]
	return String(TranslationServer.translate("Graffitty: %s\nGit revision: %s\n\nGodot: %s\nGodot revision: %s\n\nChromium: %s\nCEF build: %s\n\nPlatform: %s (%s)")) % [
		app.get("version", String(TranslationServer.translate("Unknown (build metadata unavailable)"))),
		app.get("full_revisionid", unknown),
		engine.string,
		engine.get("hash", unknown),
		chromium.get("chromium", String(TranslationServer.translate("Unknown (chromium build metadata unavailable)"))),
		chromium.get("cef", unknown),
		OS.get_name(),
		Engine.get_architecture_name(),
	]
