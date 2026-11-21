extends RefCounted
## Finds the executables that ship with the app, wherever Godot's resource
## root is. Each path is found once and cached.
##
## An upgrade may rename a running app's files, and later launches must still
## use the installed location.
static var _cli := ""
static var _app := ""

static func cli() -> String:
	var override := OS.get_environment("GRAFFITTY_BIN")
	if not override.is_empty(): return override
	if _cli.is_empty(): _cli = _locate_cli()
	return _cli if not _cli.is_empty() else ("gft.exe" if OS.get_name() == "Windows" else "gft")


static func _locate_cli() -> String:
	var name := "gft.exe" if OS.get_name() == "Windows" else "gft"
	var executable_dir := OS.get_executable_path().get_base_dir()
	var paths: Array[String] = [
		ProjectSettings.globalize_path("res://tools/" + name),
		executable_dir.path_join("../Resources/graffitty/tools").path_join(name).simplify_path(),
		executable_dir.path_join("tools").path_join(name),
		ProjectSettings.globalize_path("res://../../../dist/bin/" + name),
		ProjectSettings.globalize_path("res://../../../target/release/" + name),
		ProjectSettings.globalize_path("res://../../../target/debug/" + name),
	]
	paths.append(executable_dir.path_join(name))
	for path in paths:
		# An exported build globalizes res:// to a path relative to the working
		# directory, which a child started elsewhere cannot resolve.
		if path.is_absolute_path() and FileAccess.file_exists(path): return installed(path)
	return ""


## Relaunch through the installed entry point so a new version probes its GPU.
static func app() -> String:
	if _app.is_empty():
		var executable := OS.get_executable_path()
		var entry := ""
		match OS.get_name():
			"macOS":
				if executable.get_file() == "GraffittyRuntime": entry = "Graffitty"
			"Windows":
				if executable.get_file() == "GraffittyRuntime.exe": entry = "Graffitty.exe"
			"Linux":
				if executable.get_file() == "GraffittyRuntime": entry = "gft-gui"
		var launcher := executable.get_base_dir().path_join(entry)
		_app = installed(launcher if not entry.is_empty() and FileAccess.file_exists(launcher) else executable)
	return _app


## Returns a path to `path` that still works after an upgrade. Linux keeps
## each version in its own directory, and a `current` link points to the
## version in use.
##
## Launches go through `current` to get the new version.
static func installed(path: String) -> String:
	var version := path.get_base_dir()
	var relative := path.get_file()
	while version.get_base_dir() != version:
		var installs := version.get_base_dir()
		var directory := DirAccess.open(installs)
		var current := installs.path_join("current")
		if directory != null and directory.is_link(current) and FileAccess.file_exists(current.path_join(relative)):
			return current.path_join(relative)
		relative = version.get_file().path_join(relative)
		version = installs
	return path


## Runs the CLI to completion: {code, output (stdout), errors (stderr)}.
##
## OS.execute decodes with the Windows ANSI code page, which corrupts the
## CLI's UTF-8 on, for example, a Korean-locale machine; these bytes decode as
## UTF-8.
##
## Both pipes drain together, so a full stderr cannot stall stdout. Blocks.
static func run_cli(args: PackedStringArray) -> Dictionary:
	var process := OS.execute_with_pipe(cli(), args, false)
	if process.is_empty(): return {"code": -1, "output": "", "errors": "Cannot start " + cli()}
	var pipes: Array[FileAccess] = [process.stdio, process.stderr]
	var received: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	while true:
		# Sample before reading: an empty read after exit means fully drained.
		var running := OS.is_process_running(process.pid)
		var idle := true
		for i in pipes.size():
			var chunk := pipes[i].get_buffer(65536)
			if not chunk.is_empty():
				received[i].append_array(chunk)
				idle = false
		if idle and not running: break
		if idle: OS.delay_msec(2)
	return {"code": OS.get_process_exit_code(process.pid),
		"output": received[0].get_string_from_utf8(), "errors": received[1].get_string_from_utf8()}


static func chromium() -> String:
	var override := OS.get_environment("GODOT_CHROMIUM_HOST")
	if not override.is_empty():
		return override
	var bundle_resources := OS \
			.get_executable_path() \
			.get_base_dir() \
			.path_join("../Resources/graffitty") \
			.simplify_path()
	var bundled_host := bundle_resources.path_join("Chromium GPU Host.app/Contents/MacOS/probe")
	for base in ["res://dist/", "res://"]:
		var manifest: String = base + "chromium-host-path.txt"
		if FileAccess.file_exists(manifest):
			var relative := FileAccess.get_file_as_string(manifest).strip_edges()
			if not relative.is_absolute_path() and not ".." in relative:
				var candidate := ProjectSettings.globalize_path(base + relative)
				if FileAccess.file_exists(candidate):
					return candidate
	if FileAccess.file_exists(bundled_host):
		return bundled_host
	for path in [
		"res://dist/Chromium GPU Host.app/Contents/MacOS/probe",
		"res://Chromium GPU Host.app/Contents/MacOS/probe",
	]:
		var absolute := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(absolute):
			return absolute
	if OS.get_name() == "Windows":
		var path := ProjectSettings.globalize_path(
			"res://dist/chromium-windows/graffitty_chromium.exe"
		)
		if FileAccess.file_exists(path):
			return path
	if OS.get_name() == "Linux":
		var path := ProjectSettings.globalize_path("res://dist/chromium-linux/graffitty_chromium")
		if FileAccess.file_exists(path):
			return path
	return ""
