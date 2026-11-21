extends SceneTree
const Fonts := preload("res://scenes/remote/ServerFonts.gd")
class Connection extends Node:
	signal changed
	signal state_changed(message: String)
	var last_error := ""
	var url := "ws://test"
	var path := ""
	var requests: Array[String] = []
	func _set_state(_message: String, _args: Array = []) -> void: pass
	func request_action(kind: String, values: Dictionary, _timeout := 10000) -> Dictionary:
		requests.append(kind)
		if kind == "font_path": return {"font_path": path}
		# A real reply arrives on a later frame; panes must not wait for it.
		await get_tree().process_frame
		var bytes := FileAccess.get_file_as_bytes(path)
		return {"font_asset": {"sha256": values.sha256, "offset": values.offset, "total": bytes.size(),
			"data": Marshalls.raw_to_base64(bytes.slice(values.offset, mini(values.offset + values.max_bytes, bytes.size())))}}

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-local-font-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	Fonts.set_cache_directory("user://font-local-test-%d" % OS.get_process_id())
	_run.call_deferred()

func _run() -> void:
	var connection := Connection.new()
	root.add_child(connection)
	var bundled: Array = []
	for name in ["JetBrainsMonoNerdFont-Regular.ttf", "JetBrainsMonoNerdFont-Bold.ttf", "JetBrainsMonoNerdFont-Italic.ttf", "JetBrainsMonoNerdFont-BoldItalic.ttf", "NotoEmoji-Regular.ttf", "JuliaMono-Regular.ttf", "NotoColorEmoji.ttf"]:
		var path := ProjectSettings.globalize_path("res://../extension/fonts/" + name)
		bundled.append(_face(path))
	var fonts := Fonts.new()
	await fonts.prepare({"faces": bundled, "config": {"ligatures":true}}, connection)
	if not fonts.ready or not connection.requests.is_empty(): return _fail("Bundled fonts were downloaded")
	if not fonts.faces.all(func(face): return str(face.path).begins_with("bundled://")): return _fail("Bundled bytes were copied to disk")
	print("PASS bundled fonts need no network or disk copies")
	var family := ""
	var system_path := ""
	for candidate in OS.get_system_fonts():
		system_path = OS.get_system_font_path(candidate)
		if FileAccess.file_exists(system_path):
			family = candidate
			break
	if family.is_empty(): return _fail("No installed font available for fixture")
	var faces := bundled.duplicate(true)
	for i in 4:
		var face := _face(system_path)
		face.families = [family]
		faces.append(face)
	await fonts.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	if not fonts.ready or not connection.requests.is_empty(): return _fail("Identical installed font was downloaded")
	# Later launches skip rehashing unchanged installed fonts.
	var memo: Variant = JSON.parse_string(FileAccess.get_file_as_string(Fonts.cache_path().path_join("hashes.json")))
	if not memo is Dictionary or str(memo.get(system_path, {}).get("digest", "")) != faces[7].sha256:
		return _fail("Installed font digest was not remembered")
	print("PASS installed font reuse requires matching SHA-256")
	# Omit family hints to exercise private local-path lookup for custom files.
	for i in range(7, 11): faces[i].erase("families")
	connection.url = "ipc://test"
	connection.path = system_path
	var local_fonts := Fonts.new()
	await local_fonts.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	if not local_fonts.ready or connection.requests != ["font_path"]: return _fail("Private local font was copied over transport")
	print("PASS local custom font uses verified owner path without copying")
	# A remote owner with no matching family hint needs a single shared cache file.
	connection.url = "ws://other-server"
	connection.requests.clear()
	var remote_fonts := Fonts.new()
	remote_fonts.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	# The grid-defining primary face is local, so panes open while the
	# fallback family downloads; the renderer accepts the stand-in set.
	if not remote_fonts.ready or remote_fonts.complete or not str(remote_fonts.faces[7].path).is_empty() or remote_fonts.fetch_percent < 0:
		return _fail("Fallback font download blocked the workspace")
	if not remote_fonts._assets().retain_fonts(JSON.stringify(remote_fonts.faces)): return _fail("Renderer rejected stand-in faces")
	var no_primary: Array = remote_fonts.faces.duplicate(true)
	no_primary[0].path = ""
	if remote_fonts._assets().retain_fonts(JSON.stringify(no_primary)): return _fail("Renderer accepted a set without the grid-defining face")
	var published: int = remote_fonts.revision
	while remote_fonts.loading: await process_frame
	if not remote_fonts.complete or remote_fonts.revision != published + 1 or str(remote_fonts.faces[7].path).is_empty() or remote_fonts.fetch_percent != -1:
		return _fail("Downloaded fallback faces were not published")
	if connection.requests.is_empty(): return _fail("Remote fixture did not download font")
	print("PASS panes open before fallback fonts finish downloading")
	var stats := Fonts.cache_stats()
	if stats.files != 1 or stats.bytes <= 0: return _fail("Cache accounting is incorrect")
	var cache_path: String = remote_fonts.faces[7].path
	var clear := Fonts.clear_cache()
	if not str(clear.error).is_empty() or clear.files != 1 or Fonts.cache_stats().files != 0: return _fail("Cache clear failed: " + str(clear))
	if FileAccess.file_exists(cache_path): return _fail("Downloaded cache file still exists")
	if not FileAccess.file_exists(system_path): return _fail("System font was deleted")
	if not remote_fonts.native_assets.retain_fonts(JSON.stringify(remote_fonts.faces)): return _fail("Live fonts were lost after cache clear")
	print("PASS cache size, deletion, system-font preservation and live-font retention")
	var manager := preload("res://scenes/remote/RemoteManager.gd").new()
	root.add_child(manager)
	if manager.font_cache_clear == null or manager.font_cache_clear.text != "Clear font cache": return _fail("Server chooser has no cache control")
	manager._clear_font_cache()
	if not manager.font_cache_status.text.begins_with(tr("Font cache: %.1f MiB · files: %d") % [0.0, 0]): return _fail("Chooser cache status did not update")
	# A change right after a refresh still appears once the throttle expires.
	var late_path := Fonts.cache_path().path_join("0".repeat(64) + ".font")
	var late := FileAccess.open(late_path, FileAccess.WRITE)
	late.store_string("late")
	late.close()
	manager._refresh_font_cache()
	await create_timer(1.2).timeout
	DirAccess.remove_absolute(late_path)
	if not manager.font_cache_status.text.begins_with(tr("Font cache: %.1f MiB · files: %d") % [0.0, 1]): return _fail("Chooser cache status stayed stale after throttling")
	manager.queue_free()
	connection.queue_free()
	fonts = null
	local_fonts = null
	remote_fonts = null
	DirAccess.remove_absolute(Fonts.cache_path().path_join("hashes.json"))
	DirAccess.remove_absolute(Fonts.cache_path())
	await process_frame
	for id in Node.get_orphan_node_ids():
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	print("PASS server chooser cache action")
	quit.call_deferred(0)

func _face(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return {"sha256": FileAccess.get_sha256(path), "bytes": file.get_length(), "index": 0, "features":{}, "variations":{}, "symbol_range":null}

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
