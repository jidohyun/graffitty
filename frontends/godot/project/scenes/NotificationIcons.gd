extends RefCounted
## Resolve names before transmitted data; universal names always have a fallback.
static func resolve(names: Array, app_name: String, fallback: PackedByteArray) -> PackedByteArray:
	var candidates := names.duplicate()
	if candidates.is_empty() and not app_name.is_empty(): candidates.append(app_name)
	for candidate in candidates:
		var name := str(candidate)
		if name.is_empty() or name.contains("/") or name.contains("\\") or name in [".", ".."]: continue
		if OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD"]:
			var theme_name: String = {"error":"dialog-error", "warn":"dialog-warning", "warning":"dialog-warning", "info":"dialog-information", "question":"dialog-question", "help":"help-chromium", "file-manager":"system-file-manager", "system-monitor":"utilities-system-monitor", "text-editor":"accessories-text-editor"}.get(name, name)
			var roots := [OS.get_environment("HOME").path_join(".local/share/icons"), "/usr/share/icons", "/usr/local/share/icons"]
			for root in roots:
				for theme in ["hicolor", "Adwaita", "gnome"]:
					for size in ["256x256", "128x128", "64x64", "48x48", "scalable"]:
						for group in ["apps", "status", "devices", "mimetypes", "actions"]:
							for suffix in ["png", "svg"]:
								var path: String = root.path_join("%s/%s/%s/%s.%s" % [theme, size, group, theme_name, suffix])
								if not FileAccess.file_exists(path): continue
								var file := FileAccess.open(path, FileAccess.READ)
								if file == null or file.get_length() > 4 * 1024 * 1024: continue
								var bytes := file.get_buffer(file.get_length())
								if suffix == "png": return bytes
								var themed := Image.new()
								if themed.load_svg_from_string(bytes.get_string_from_utf8()) == OK: return themed.save_png_to_buffer()
		var path: String = {
			"error": '<path d="m80 80 96 96m0-96-96 96"/>',
			"warn": '<path d="M128 56 216 204H40Z M128 104v44m0 24v4"/>',
			"warning": '<path d="M128 56 216 204H40Z M128 104v44m0 24v4"/>',
			"info": '<path d="M128 112v68m0-104v4"/>',
			"question": '<path d="M92 96c0-48 88-48 76 0-4 20-40 20-40 52m0 24v4"/>',
			"help": '<circle cx="128" cy="128" r="64"/><circle cx="128" cy="128" r="28"/><path d="m84 84 24 24m40 40 24 24m0-88-24 24m-40 40-24 24"/>',
			"file-manager": '<path d="M48 88h64l20 20h76v84H48Z"/>',
			"system-monitor": '<path d="M44 64h168v116H44Z m64 140h40m-20-24v24 M60 132h24l16-36 24 60 20-40h48"/>',
			"text-editor": '<path d="M72 48h112v160H72Z m24 40h64m-64 32h64m-64 32h48"/>'
		}.get(name, "")
		if path.is_empty(): continue
		var image := Image.new()
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><rect x="8" y="8" width="240" height="240" rx="48" fill="#254c75"/><g fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>' % path
		if image.load_svg_from_string(svg) == OK: return image.save_png_to_buffer()
	return fallback
