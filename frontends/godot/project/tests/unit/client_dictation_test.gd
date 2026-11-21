extends "res://tests/unit/test_case.gd"
const Client := preload("res://scenes/input/ClientDictation.gd")

class MemoryStore extends "res://scenes/remote/CredentialStore.gd":
	var keys := {}
	func credential(operation: String, account: String, password := "") -> Dictionary:
		match operation:
			"set": keys[account] = password
			"delete": keys.erase(account)
		return {"password": keys.get(account, "")}

func test_provider_selection_and_separate_credentials() -> void:
	var store := MemoryStore.new()
	assert(Client.save_selection("gemini", "fixture-google", store))
	assert(Client.save_selection("openai", "fixture-openai", store))
	assert(Client.credential(store) == {"provider":"openai", "password":"fixture-openai"})
	assert(Client.save_selection("gemini", "", store))
	assert(Client.credential(store).password == "fixture-google")
	assert(Client.save_selection("server", "", store))
	assert(Client.credential(store).password == "")
	assert(not Client.save_selection("gemini", "", store))
	assert(Client.save_selection("openai", "", store))
	store.keys.clear()
	assert(Client.credential(store).has("error"))
	assert(Client.save_selection("server", "", store))

func test_provider_protocol_and_settings_load() -> void:
	var protocol: RefCounted = ClassDB.instantiate("ClientDictationProtocol")
	var request: Dictionary = protocol.prepare_request("gemini", "fixture", PackedByteArray([1, 2]))
	var body: Dictionary = JSON.parse_string(request.body.get_string_from_utf8())
	var wav := Marshalls.base64_to_raw(body.contents[0].parts[1].inlineData.data)
	assert(wav.size() == 46)
	assert(wav.slice(0, 4).get_string_from_ascii() == "RIFF")
	var result: Dictionary = protocol.parse_response("gemini", 200, '{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}')
	assert(result.text == "hello")
	var dialog := preload("res://scenes/input/ClientDictationSettings.gd").new()
	dialog._ready()
	assert(dialog.provider.item_count == 2)
	assert(dialog.provider.get_item_text(1) == "OpenAI")
	dialog.key.text = "fixture"
	dialog.provider.select(1)
	dialog.provider.item_selected.emit(1)
	assert(dialog.key.text.is_empty())
	dialog.free()
