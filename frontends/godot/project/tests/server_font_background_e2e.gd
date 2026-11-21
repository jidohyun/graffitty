extends SceneTree
## A client without the owner's CJK font opens panes on the grid-defining face,
## draws Hangul with a device stand-in, then swaps the downloaded face in place.
const Fonts := preload("res://scenes/remote/ServerFonts.gd")

class DeviceFonts extends "res://scenes/remote/ServerFonts.gd":
	var hold := true
	# Like a phone: bundled faces match the owner, its installed fonts do not.
	func _local_font(face: Dictionary, connection: Node) -> String:
		var path: String = await super._local_font(face, connection)
		return path if path.begins_with("bundled://") else ""
	# Keep the background download pending while the stand-in is inspected.
	func _download(index: int, ticket: int, connection: Node) -> bool:
		while hold and index > 0: await connection.get_tree().process_frame
		return await super._download(index, ticket, connection)

const TestServer := preload("res://tests/support/TestServer.gd")
var directory := ""
var server_pid := -1
var failed := false
var guard := preload("res://tests/diagnostic_guard.gd").new()

func _initialize() -> void:
	directory = TestServer.prepare("graffitty-font-background")
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	Fonts.set_cache_directory("user://font-background-test-%d" % OS.get_process_id())
	guard.install(self)
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failed = true

func until(condition: Callable, seconds := 30.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func hangul(terminal: Node) -> Array:
	return terminal.cell_glyphs().filter(func(cell): return int(cell.cp) == 0xD55C).map(func(cell): return [cell.col, cell.row, cell.wide, cell.font])

func _run() -> void:
	var binary := OS.get_environment("GRAFFITTY_TEST_SERVER")
	if binary.is_empty(): binary = ProjectSettings.globalize_path("res://../../../target/debug/gft")
	DirAccess.make_dir_recursive_absolute(directory)
	server_pid = OS.create_process(binary, ["server", "--listen", "127.0.0.1:0", "--connection", directory.path_join("server.json"), "--auth-file", directory.path_join("auth.json"), "--shell", "/bin/sh"])
	if not await until(func(): return FileAccess.file_exists(directory.path_join("server.json"))):
		return _finish("Server did not start")
	var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("server.json")))
	var client: Node = load("res://scenes/remote_client.tscn").instantiate()
	client.settings = {"url": settings.url, "token": settings.token}
	var fonts := DeviceFonts.new()
	client.connection.server_fonts = fonts
	var opened := {}
	client.connection.changed.connect(func():
		if opened.is_empty() and client.host != null and not client.host.sessions.is_empty():
			opened.complete = fonts.complete
			opened.pending = fonts.faces.filter(func(face): return str(face.path).is_empty()).size())
	root.add_child(client)
	check(await until(func(): return not opened.is_empty()), "Panes open on the grid-defining primary face")
	if opened.is_empty(): return _finish("No panes")
	if fonts.manifest_faces.size() <= 7:
		print("SKIP the server has no installed CJK fallback family")
		return _finish("")
	check(not opened.complete and opened.pending > 0, "The owner's CJK fallback is still downloading when panes open")
	var progress: String = client.connection.status_message
	check(progress.begins_with("Connected · fetching fonts") and fonts.fetch_percent >= 0, "Connection status reports background font progress: " + progress)
	var terminal: Node = client.host.sessions[client.host.active_session_id].term
	terminal.send_text("printf '\\n한글 ABC\\n'\r")
	check(await until(func(): return not hangul(terminal).is_empty()), "Hangul arrives while the fallback face is pending")
	var before := hangul(terminal)
	var grid: Vector2i = terminal.get_grid_size()
	check(before.all(func(cell): return cell[2] and cell[3] >= 0), "A device stand-in draws wide Hangul cells instead of blanks")
	check(str(terminal.get_meta("server_font_signature", "")).contains("\"path\":\"\""), "Renderer applied the set with pending faces")
	fonts.hold = false
	check(await until(func(): return fonts.complete, 60.0), "Fallback download completes in the background")
	check(await until(func(): return not str(terminal.get_meta("server_font_signature", "")).contains("\"path\":\"\"")), "Downloaded faces replace the stand-ins in open panes")
	var after := hangul(terminal)
	check(after.size() == before.size() and terminal.get_grid_size() == grid, "Rows, columns and Hangul cells stay put across the swap")
	check(after.all(func(cell): return cell[3] >= 0) and after.map(func(cell): return cell.slice(0, 3)) == before.map(func(cell): return cell.slice(0, 3)), "Downloaded face draws the same cells")
	check(client.connection.status_message == "Connected" and fonts.fetch_percent == -1, "Status returns to Connected")
	check(Fonts.cache_stats().files == 1, "The fallback collection is cached once")
	check(guard.failures.is_empty(), "No unexpected diagnostics")
	client.queue_free()
	await process_frame
	var clear := Fonts.clear_cache()
	check(str(clear.error).is_empty(), "Downloaded test font removed")
	_finish("")

func _finish(error: String) -> void:
	if not error.is_empty(): check(false, error)
	TestServer.stop(server_pid, directory, failed)
	DirAccess.remove_absolute(Fonts.cache_path().path_join("hashes.json"))
	DirAccess.remove_absolute(Fonts.cache_path())
	print("SERVER_FONT_BACKGROUND_E2E_%s" % ("FAIL" if failed else "PASS"))
	quit(1 if failed else 0)
