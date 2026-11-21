extends RefCounted
## Verified fonts shared across servers; only private local owners expose paths.
# The cache can contain native objects; release it with the scene root.
static func _state() -> Dictionary:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_font_cache"):
		owner.set_meta("graffitty_font_cache", {"downloads": {}, "received": {}, "instances": [], "directory": "user://server-fonts"})
	return owner.get_meta("graffitty_font_cache")

static func cache_path() -> String:
	return str(_state().directory)

static func set_cache_directory(path: String) -> void:
	_state().directory = path
	_state().erase("native_cache")

var generation := 0
var signature := ""
## The owner derives every grid from its regular primary face alone, so panes
## may open once that face matches. Other faces only change glyph appearance.
var ready := false
## Every face matches the owner's bytes. Until then, pending faces render with
## client stand-ins, and `revision` changes when the downloaded faces arrive.
var complete := false
var loading := false
var faces: Array = []
var revision := 0
## Percent of the background download, or -1 when nothing is being fetched.
var fetch_percent := -1
var error := ""
var native_assets: RefCounted
var local_paths: Dictionary[String, String] = {}
var manifest_faces: Array = []
var config: Dictionary = {}
var resolved: Array = []
var chunk_bytes := 32768
var fetched := 0
var fetching := 0
var counted: Dictionary[String, bool] = {}

func _init() -> void:
	for index in range(_state().instances.size() - 1, -1, -1):
		if not is_instance_id_valid(_state().instances[index]): _state().instances.remove_at(index)
	_state().instances.append(get_instance_id())

func prepare(manifest: Dictionary, connection: Node) -> void:
	if not manifest.get("config") is Dictionary or not manifest.get("faces") is Array:
		_fail("Invalid server font manifest", connection)
		return
	for face in manifest.faces:
		if not face is Dictionary or not face.get("features") is Dictionary or not face.get("variations") is Dictionary or not face.has("symbol_range"):
			_fail("Invalid server font face metadata", connection)
			return
	var next := JSON.stringify(manifest)
	if next == signature and (complete or loading or not error.is_empty()): return
	_release_downloads()
	generation += 1
	var ticket := generation
	if next != signature:
		signature = next
		ready = false
		complete = false
		faces = []
		manifest_faces = manifest.get("faces", [])
		config = manifest.config.duplicate(true)
		resolved = []
		resolved.resize(manifest_faces.size())
	loading = true
	error = ""
	chunk_bytes = 32768
	if manifest_faces.size() < 7:
		_fail("Server font manifest has no complete font set", connection)
		return
	for face in manifest_faces:
		var hash := str(face.get("sha256", ""))
		var length := int(face.get("bytes", 0))
		if hash.length() != 64 or not hash.is_valid_hex_number() or length <= 0 or length > 67108864:
			_fail("Invalid server font manifest", connection)
			return
	if not ready: connection._set_state("Loading server fonts…")
	DirAccess.make_dir_recursive_absolute(cache_path())
	# Bundled, installed, owner-local and cached faces need no transfer.
	var missing: Array[int] = []
	for i in manifest_faces.size():
		if resolved[i] != null: continue
		var path: String = await _available(manifest_faces[i], connection)
		if generation != ticket: return
		if path.is_empty(): missing.append(i)
		else: resolved[i] = path
	if not missing.is_empty() and missing[0] == 0:
		if not await _download(0, ticket, connection): return
		# Styles stored in the primary face's file arrived with it.
		for i in missing.duplicate():
			if manifest_faces[i].sha256 == manifest_faces[0].sha256:
				resolved[i] = resolved[0]
				missing.erase(i)
	ready = true
	if not missing.is_empty():
		# Fetch the rest while panes render; faces sharing a file count once.
		fetched = 0
		fetching = 0
		counted = {}
		var sizes := {}
		for i in missing: sizes[manifest_faces[i].sha256] = int(manifest_faces[i].bytes)
		for size in sizes.values(): fetching += size
		_publish(connection)
		for i in missing:
			if not await _download(i, ticket, connection): return
	complete = true
	loading = false
	fetch_percent = -1
	_publish(connection)

# Pending faces have no path; the renderer substitutes client stand-ins until
# `complete`, so each publication bumps the revision panes compare against.
func _publish(connection: Node) -> void:
	faces = []
	for i in manifest_faces.size():
		faces.append({"path": str(resolved[i]) if resolved[i] != null else "", "index": int(manifest_faces[i].get("index", 0)), "features": manifest_faces[i].features, "variations": manifest_faces[i].variations, "symbol_range": manifest_faces[i].symbol_range})
	revision += 1
	if complete: connection._set_state("Connected")
	else: _report(connection, 0, 0)
	connection.changed.emit()

func _available(face: Dictionary, connection: Node) -> String:
	var local: String = await _local_font(face, connection)
	if not local.is_empty(): return local
	var path := cache_path().path_join(str(face.sha256) + ".font")
	return ProjectSettings.globalize_path(path) if _sha256(path) == str(face.sha256) else ""

func _download(index: int, ticket: int, connection: Node) -> bool:
	var hash := str(manifest_faces[index].sha256)
	var length := int(manifest_faces[index].bytes)
	# All servers share the verified cache and one in-flight request chain
	# per content hash. A failed/disconnected owner releases the download.
	while _download_busy(hash):
		await connection.get_tree().process_frame
		if generation != ticket: return false
		_report(connection, int(_state().received.get(hash, 0)), length)
	var path := cache_path().path_join(hash + ".font")
	if _sha256(path) != hash:
		_state().downloads[hash] = get_instance_id()
		# Another connection can resume this partial after cancellation.
		# Separate processes never write the same partial file.
		var offset: int = _cache().begin_download(hash, length, OS.has_feature("mobile"))
		if offset < 0:
			_fail("Cannot write server font cache", connection)
			return false
		while offset < length:
			# Aim for 150 ms per response instead of paying a round trip for
			# every 32 KiB on fast links. Keep just one request outstanding.
			var started := Time.get_ticks_msec()
			var reply: Dictionary = await connection.request_action("font_asset", {"sha256": hash, "offset": offset, "max_bytes": chunk_bytes}, 60000)
			if generation != ticket: return false
			var asset: Dictionary = reply.get("font_asset", {})
			var chunk := Marshalls.base64_to_raw(str(asset.get("data", "")))
			if asset.get("sha256", "") != hash or int(asset.get("offset", -1)) != offset or int(asset.get("total", -1)) != length or chunk.is_empty() or offset + chunk.size() > length:
				_fail("Server font download failed: %s", connection, [str(reply.get("message", hash))])
				return false
			offset = _cache().append_download(hash, length, offset, chunk)
			if offset < 0:
				_fail("Cannot write server font cache", connection)
				return false
			_state().received[hash] = offset
			var elapsed := maxi(1, Time.get_ticks_msec() - started)
			# JSON/base64 font replies are consumed on the UI thread. The packet
			# time budget cannot preempt one large reply; keep mobile chunks small
			# enough that cold-cache downloads do not stall touch and scene updates.
			var max_chunk_bytes := 65536 if OS.has_feature("mobile") else 524288
			chunk_bytes = clampi(int(float(chunk.size()) * 150.0 / elapsed), 32768, max_chunk_bytes)
			_report(connection, offset, length)
		var completed_path: String = _cache().finish_download(hash, length)
		if completed_path.is_empty():
			_fail("Server font download failed: %s", connection, [_cache().last_error()])
			return false
	_state().downloads.erase(hash)
	_state().received.erase(hash)
	resolved[index] = ProjectSettings.globalize_path(path)
	if ready and not counted.has(hash):
		counted[hash] = true
		fetched += length
	return true

# `received` bytes of the face currently in flight, shared by every connection
# waiting for the same content hash.
func _report(connection: Node, received: int, length: int) -> void:
	if not ready:
		connection._set_state("Loading server fonts… %d%%", [100 * received / maxi(1, length)])
		return
	var percent := mini(99, 100 * (fetched + received) / maxi(1, fetching))
	if percent == fetch_percent: return
	fetch_percent = percent
	connection._set_state("Connected · fetching fonts %d%%", [percent])

func _fail(message: String, connection: Node, args: Array = []) -> void:
	_release_downloads()
	loading = false
	fetch_percent = -1
	error = message if args.is_empty() else message % args
	connection.last_error = error
	connection._set_state(message, args)

func cancel_download() -> void:
	if not loading and error.is_empty(): return
	_release_downloads()
	generation += 1
	error = ""
	loading = false
	fetch_percent = -1
	# A usable font set survives reconnects; prepare() then resumes the faces
	# still missing for the same manifest without closing open panes.
	if not ready: signature = ""

func _download_busy(hash: String) -> bool:
	var owner: RefCounted = _instance(_state().downloads[hash]) if _state().downloads.has(hash) else null
	return owner != null and owner != self and owner.loading

func _release_downloads() -> void:
	for hash in _state().downloads.keys():
		if _state().downloads[hash] == get_instance_id():
			_state().downloads.erase(hash)
			_state().received.erase(hash)

func _assets() -> RefCounted:
	if native_assets == null and ClassDB.class_exists("ServerFontAssets"):
		native_assets = ClassDB.instantiate("ServerFontAssets")
	return native_assets

func _local_font(face: Dictionary, connection: Node) -> String:
	var hash: String = face.sha256
	if local_paths.has(hash): return str(local_paths[hash])
	var assets := _assets()
	if assets != null:
		var bundled: String = assets.bundled_path(hash)
		if not bundled.is_empty():
			local_paths[hash] = bundled
			return bundled
	var checked: Array[String] = []
	for family in face.get("families", []):
		var path := OS.get_system_font_path(str(family), int(face.get("weight", 400)), 100, bool(face.get("italic", false)))
		if path.is_empty() or path in checked: continue
		checked.append(path)
		if _sha256(path) == hash:
			local_paths[hash] = path
			return path
	# Only a direct private transport may resolve server filesystem paths.
	# Remote servers cannot ask us to open arbitrary local files.
	var endpoint := str(connection.get("url"))
	if endpoint == "shared://local" or endpoint.begins_with("ipc://"):
		var reply: Dictionary = await connection.request_action("font_path", {"sha256": hash})
		var path := str(reply.get("font_path", ""))
		if not path.is_empty() and _sha256(path) == hash:
			local_paths[hash] = path
			return path
	return ""

# Hashing a 55 MiB CJK collection takes ~0.2 s. Remember verified digests by
# path, size and modification time so launches and reconnects skip rehashing.
static func _cache() -> RefCounted:
	if not _state().has("native_cache"):
		var cache: RefCounted = ClassDB.instantiate("FontCacheStore")
		cache.configure(ProjectSettings.globalize_path(cache_path()))
		_state().native_cache = cache
	return _state().native_cache

static func _sha256(path: String) -> String:
	return _cache().hash(ProjectSettings.globalize_path(path))

static func _remember_sha256(path: String, digest: String) -> void:
	_cache().remember(ProjectSettings.globalize_path(path), digest)

static func _adopt_partial(path: String, temporary: String) -> void:
	_cache().adopt_partial(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(temporary), OS.has_feature("mobile"))

static func _length(path: String) -> int:
	return _cache().length(ProjectSettings.globalize_path(path))

static func cache_stats() -> Dictionary:
	var result: Dictionary = _cache().stats()
	result.downloading = false
	for item in _state().downloads.values():
		var owner: RefCounted = _instance(item)
		if owner != null and owner.loading: result.downloading = true
	return result

static func _cache_files() -> Array[String]:
	return _cache().files()

static func clear_cache() -> Dictionary:
	var result := {"bytes": 0, "files": 0, "error": ""}
	if cache_stats().downloading:
		result.error = "Wait for the current font download to finish."
		return result
	# Keep live font data in memory before deleting its disk copy. New panes on
	# these connections can keep using it until they disconnect.
	var directory := ProjectSettings.globalize_path(cache_path()) + "/"
	for item in _state().instances:
		var owner: RefCounted = _instance(item)
		if owner == null or not owner.ready: continue
		var uses_cache := false
		for face in owner.faces:
			if str(face.path).begins_with(directory): uses_cache = true
		if not uses_cache: continue
		var assets: RefCounted = owner._assets()
		if assets == null or not assets.retain_fonts(JSON.stringify(owner.faces)):
			result.error = "Could not preserve fonts for an active connection."
			return result
	return _cache().clear()

static func _instance(id: int) -> RefCounted:
	return instance_from_id(id) if is_instance_id_valid(id) else null
