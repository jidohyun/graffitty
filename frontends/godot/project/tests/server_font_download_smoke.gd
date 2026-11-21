extends SceneTree
## Interrupted downloads resume at the last persisted chunk, with final hashing.
class Connection extends Node:
	signal changed
	signal state_changed(message: String)
	var last_error := ""
	var bytes := PackedByteArray()
	var offsets: Array[int] = []
	var limits: Array[int] = []
	var interrupt := true
	func _set_state(_message: String, _args: Array = []) -> void: pass
	func request_action(_kind: String, values: Dictionary, _timeout: int = 10000) -> Dictionary:
		offsets.append(int(values.offset))
		limits.append(int(values.max_bytes))
		await get_tree().process_frame
		if interrupt and values.offset > 0:
			return {"message": "Simulated disconnect"}
		return {"font_asset": {"sha256": values.sha256, "offset": values.offset,
			"total": bytes.size(), "data": Marshalls.raw_to_base64(bytes.slice(values.offset, mini(values.offset + int(values.max_bytes), bytes.size())))}}

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-font-download-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	preload("res://scenes/remote/ServerFonts.gd").set_cache_directory("user://font-download-test-%d" % OS.get_process_id())
	_run.call_deferred()

func _run() -> void:
	var connection := Connection.new()
	root.add_child(connection)
	connection.bytes.resize(100000)
	for i in connection.bytes.size(): connection.bytes[i] = (i * 17 + OS.get_process_id()) % 256
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(connection.bytes)
	var hash := digest.finish().hex_encode()
	var path := preload("res://scenes/remote/ServerFonts.gd").cache_path().path_join(hash + ".font")
	DirAccess.remove_absolute(path)
	var downloader := preload("res://scenes/remote/ServerFonts.gd").new()
	var faces: Array = []
	for i in 7: faces.append({"sha256": hash, "bytes": connection.bytes.size(), "index": i, "features":{}, "variations":{}, "symbol_range":null})
	await downloader.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	if downloader.ready or downloader.error.is_empty(): return _fail("Disconnect was not detected")
	downloader.cancel_download()
	connection.interrupt = false
	connection.offsets.clear()
	connection.limits.clear()
	await downloader.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	if not downloader.ready: return _fail(downloader.error)
	if connection.offsets[0] != 32768: return _fail("Download restarted instead of resuming")
	if FileAccess.get_sha256(path) != hash: return _fail("Cache hash mismatch")
	if connection.offsets.size() != 2: return _fail("Fast transfer did not reduce request count")
	if connection.limits[1] <= connection.limits[0]: return _fail("Fast transfer did not grow chunks")
	# A distinct server/connection with the same bytes must use the disk cache.
	var second := Connection.new()
	second.bytes = connection.bytes
	second.interrupt = false
	root.add_child(second)
	var other := preload("res://scenes/remote/ServerFonts.gd").new()
	await other.prepare({"faces": faces, "default_size": 24, "config": {"ligatures":true}}, second)
	if not other.ready or not second.offsets.is_empty(): return _fail("Another server redownloaded the same hash")
	# Two cold connections must share a single download too.
	DirAccess.remove_absolute(path)
	downloader.cancel_download()
	downloader.signature = ""
	other.signature = ""
	connection.offsets.clear()
	downloader.prepare({"faces": faces, "config": {"ligatures":true}}, connection)
	await other.prepare({"faces": faces, "config": {"ligatures":true}}, second)
	if not downloader.ready or not other.ready or not second.offsets.is_empty(): return _fail("Concurrent servers duplicated the download")
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_string("corrupt cache")
	corrupt.close()
	other.signature = ""
	await other.prepare({"faces": faces, "config": {"ligatures":true}}, second)
	if not other.ready or second.offsets.is_empty() or FileAccess.get_sha256(path) != hash:
		return _fail("Corrupt cache was not replaced with verified content")
	# A relaunched app has a new process ID; it resumes the partial that its
	# exited predecessor left instead of restarting or leaking it.
	DirAccess.remove_absolute(path)
	var stale := path + ".1.part"
	var partial := FileAccess.open(stale, FileAccess.WRITE)
	partial.store_buffer(connection.bytes.slice(0, 40000))
	partial.close()
	if OS.execute("touch", ["-m", "-t", "202001010000", ProjectSettings.globalize_path(stale)]) != 0:
		return _fail("Cannot age partial fixture")
	second.offsets.clear()
	other.signature = ""
	await other.prepare({"faces": faces, "config": {"ligatures":true}}, second)
	var resumed := other.ready and not second.offsets.is_empty() and second.offsets[0] == 40000
	DirAccess.remove_absolute(stale)
	if not resumed or FileAccess.get_sha256(path) != hash: return _fail("Partial from an exited process was not resumed")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir().path_join("hashes.json"))
	DirAccess.remove_absolute(path.get_base_dir())
	other = null
	second.free()
	print("PASS font resume, restart resume, adaptive transfer, hash verification and cross-server cache/deduplication")
	connection.free()
	downloader = null
	for id in Node.get_orphan_node_ids():
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	quit.call_deferred(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
