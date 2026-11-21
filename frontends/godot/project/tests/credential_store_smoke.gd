extends Node
## Two launches verify persistence, not just an in-memory round trip.
const Store := preload("res://scenes/remote/CredentialStore.gd")
const ACCOUNT := "graffitty-credential-store-self-test"
var marker := "user://credential-test-digest"


func _ready() -> void:
	var store := Store.new()
	if not FileAccess.file_exists(marker):
		var password := "한글 🔑 café " + Crypto.new().generate_random_bytes(32).hex_encode()
		var result := store.credential("set", ACCOUNT, password)
		if not result.get("ok", false):
			finish("FAIL save: " + str(result.error), 1)
			return
		var file := FileAccess.open(marker, FileAccess.WRITE)
		file.store_string(password.sha256_text())
		file.close()
		finish("PASS saved in OS credential store; restart for retrieval", 0)
	else:
		var expected := FileAccess.get_file_as_string(marker)
		var result := store.credential("get", ACCOUNT)
		if result.has("error") or str(result.get("password", "")).sha256_text() != expected:
			finish("FAIL retrieval after restart: " + str(result.get("error", "mismatch")), 1)
			return
		result = store.credential("delete", ACCOUNT)
		if not result.get("ok", false):
			finish("FAIL delete: " + str(result.error), 1)
			return
		result = store.credential("get", ACCOUNT)
		if result.has("error") or not str(result.get("password", "")).is_empty():
			finish("FAIL password still exists after deletion", 1)
			return
		DirAccess.remove_absolute(marker)
		finish("PASS retrieved after restart and deleted", 0)


func finish(message: String, code: int) -> void:
	print("[credential test] " + message)
	var file := FileAccess.open("user://credential-test-result", FileAccess.WRITE)
	file.store_string(message)
	file.close()
	get_tree().quit(code)
