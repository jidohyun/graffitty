extends Node
## Settings adapter. The common server owns authentication and the listener.
var connection: Node
var enabled := false
var token := ""
var address := ""
var connection_file := ""
var auth_path := ""
var last_error := ""
## Why remote access the server was configured for is off: the server's
## `remote_error`, or empty.
var unavailable := {}
var _alias := ""

func bind(app: Node) -> bool:
	for host in app.hosts:
		var backend: RefCounted = host.session_backend
		if "connection" in backend:
			var candidate: Node = backend.connection
			if "url" in candidate and (candidate.url == "shared://local" or candidate.url.begins_with("ipc://")):
				connection = candidate
				return true
	last_error = "Remote access settings require a local session owner"
	return false

func refresh() -> Error:
	var reply: Dictionary = await _request("auth_settings")
	if reply.type == "error": return ERR_CONNECTION_ERROR
	_install_settings(reply.result)
	return OK

func _install_settings(settings: Dictionary) -> void:
	auth_path = str(settings.auth_path)
	if _alias.is_empty(): connection_file = str(settings.connection_file)
	_install_remote(settings.get("remote"))
	var failure: Variant = settings.get("remote_error")
	unavailable = failure if failure is Dictionary else {}


## The reason in `unavailable` in the user's language.
func unavailable_text() -> String:
	if unavailable.is_empty(): return ""
	var where := str(unavailable.get("address", ""))
	match str(unavailable.get("holder", "")):
		"graffitty": return tr("%s is in use by another Graffitty server (process %d).") % [where, int(unavailable.get("pid", 0))]
		"program": return tr("%s is in use by %s (process %d).") % [where, str(unavailable.get("name", "")), int(unavailable.get("pid", 0))]
		"unknown": return tr("%s is in use by another program.") % where
	return str(unavailable.get("message", ""))

func _install_remote(remote: Variant) -> void:
	enabled = remote is Dictionary
	token = str(remote.get("token", "")) if enabled else ""
	address = str(remote.get("url", "")) if enabled else ""

func _request(kind: String, values: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(connection) or not connection.connected:
		last_error = "Session owner is disconnected"
		return {"type": "error", "message": last_error}
	var reply: Dictionary = await connection.request_action(kind, values)
	last_error = str(reply.get("message", "")) if reply.type == "error" else ""
	return reply

func start(app: Node, bind_address: String, port: int, descriptor := "") -> Error:
	if not bind(app): return ERR_UNAVAILABLE
	if await refresh() != OK: return ERR_CONNECTION_ERROR
	var canonical := connection_file
	# Reload settings saved by the local password dialog. Starting sharing gives
	# temporary credentials a new lifetime without restarting any session.
	var reply: Dictionary = await _request("auth_reload", {"rotate": false})
	if reply.type == "error": return ERR_INVALID_DATA
	if reply.result.temporary_enabled:
		reply = await _request("auth_reload", {"rotate": true})
		if reply.type == "error": return ERR_INVALID_DATA
	_install_settings(reply.result)
	var request := {"enabled": true}
	if not bind_address.is_empty(): request.address = "%s:%d" % [bind_address, port]
	reply = await _request("remote_access", request)
	if reply.type == "error": return ERR_CANT_CREATE
	_install_remote(reply.result)
	# An explicit connection-file export retains the CLI pairing contract. The
	# private owner descriptor is always kept, including when sharing is off.
	if not descriptor.is_empty() and descriptor != canonical:
		_alias = descriptor
		connection_file = descriptor
		var error := _publish_alias(reply.result)
		if error != OK:
			await stop()
			return error
	return OK

func reload(rotate := false) -> Error:
	var reply: Dictionary = await _request("auth_reload", {"rotate": rotate})
	if reply.type == "error": return ERR_INVALID_DATA
	_install_settings(reply.result)
	if enabled and not _alias.is_empty(): return _publish_alias(reply.result.remote)
	return OK

func stop() -> Error:
	var reply: Dictionary = await _request("remote_access", {"enabled": false})
	if reply.type == "error": return ERR_CONNECTION_ERROR
	_install_remote(reply.result)
	if not _alias.is_empty():
		DirAccess.remove_absolute(_alias)
		_alias = ""
	return OK

func _publish_alias(remote: Dictionary) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(_alias.get_base_dir())
	if error != OK: return error
	var temporary := _alias + ".%d.tmp" % OS.get_process_id()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return FileAccess.get_open_error()
	if OS.get_name() != "Windows":
		error = FileAccess.set_unix_permissions(temporary, 384)
		if error != OK:
			file.close()
			DirAccess.remove_absolute(temporary)
			return error
	file.store_string(JSON.stringify(remote))
	file.close()
	return DirAccess.rename_absolute(temporary, _alias)
