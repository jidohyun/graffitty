extends Node
## Device-local provider. No host RPC or credentials fallback on failure.
signal changed(text: String)
signal finished
signal failed(message: String)
const Store := preload("res://scenes/remote/CredentialStore.gd")
const PROVIDERS := ["gemini", "openai"]
var provider := ""
var audio := PackedByteArray()
var api_key := ""
var request: HTTPRequest
var canceled := false
var stopping := false

static func preference_path() -> String:
	return preload("res://graffitty/paths.gd").stdpath("config").path_join("client-dictation.conf")

static func selected_provider() -> String:
	var config := ConfigFile.new()
	var err := config.load(preference_path())
	if err == ERR_FILE_NOT_FOUND: return "server"
	if err != OK: return ""
	return str(config.get_value("dictation", "provider", ""))

static func credential(store: Store = Store.new()) -> Dictionary:
	var selected := selected_provider()
	if selected == "server": return {"password": ""}
	if selected not in PROVIDERS: return {"error": "Invalid provider"}
	var result := store.credential("get", "client-dictation-" + selected)
	if str(result.get("password", "")).is_empty(): return {"error": "Missing key"}
	return {"provider": selected, "password": result.password}

static func save_selection(selected: String, value: String, store: Store = Store.new()) -> bool:
	if selected == "server":
		var previous := selected_provider()
		if previous in PROVIDERS and store.credential("delete", "client-dictation-" + previous).has("error"):
			return false
	elif selected in PROVIDERS:
		var account := "client-dictation-" + selected
		if value.is_empty():
			if str(store.credential("get", account).get("password", "")).is_empty(): return false
		elif store.credential("set", account, value).has("error"):
			return false
	else:
		return false
	var config := ConfigFile.new()
	config.set_value("dictation", "provider", selected)
	var path := preference_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return config.save(path + ".tmp") == OK and DirAccess.rename_absolute(path + ".tmp", path) == OK

func start(config: Dictionary) -> void:
	provider = str(config.get("provider", ""))
	api_key = str(config.get("password", ""))
	if config.has("error") or provider not in PROVIDERS or api_key.is_empty():
		failed.emit(tr("Check the API key saved on this device."))

func accept(pcm: PackedByteArray) -> void:
	if canceled or stopping: return
	if audio.size() + pcm.size() > 48000 * 2 * 60:
		cancel()
		failed.emit(tr("Client dictation failed"))
		return
	audio.append_array(pcm)

func stop() -> void:
	if canceled or stopping: return
	stopping = true
	var protocol: RefCounted = ClassDB.instantiate("ClientDictationProtocol")
	var upload: Dictionary = protocol.prepare_request(provider, api_key, audio)
	api_key = ""
	audio.clear()
	if upload.has("error"):
		failed.emit(tr(upload.error))
		return
	_upload(upload, protocol)

func _upload(upload: Dictionary, protocol: RefCounted) -> void:
	request = HTTPRequest.new()
	request.timeout = 30
	request.max_redirects = 0
	request.body_size_limit = 1024 * 1024
	add_child(request)
	request.request_completed.connect(_completed.bind(protocol))
	var error := request.request_raw(upload.url, upload.headers, HTTPClient.METHOD_POST, upload.body)
	if error != OK: failed.emit(tr("Client dictation failed"))

func _completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray, protocol: RefCounted) -> void:
	if canceled: return
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit(tr("Client dictation failed"))
		return
	var response: Dictionary = protocol.parse_response(provider, status, body.get_string_from_utf8())
	if response.has("error"):
		failed.emit(tr(response.error))
		return
	changed.emit(str(response.get("text", "")))
	finished.emit()

func cancel() -> void:
	canceled = true
	audio.clear()
	api_key = ""
	if is_instance_valid(request): request.cancel_request()

func _exit_tree() -> void:
	cancel()
