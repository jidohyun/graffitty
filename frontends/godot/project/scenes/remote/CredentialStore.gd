extends RefCounted
## Desktop and iOS credentials live in the OS vault. Android stores AES-GCM ciphertext
## in private app storage; the non-exportable encryption key stays in AndroidKeyStore.
var error := ""
var bridge: Object


func credential(operation: String, account: String, password := "") -> Dictionary:
	if not OS.has_feature("android"):
		var native: RefCounted = ClassDB.instantiate("RemoteAuth")
		return JSON.parse_string(native.credential(operation, account, password))
	bridge = Engine.get_singleton("JavaClassWrapper")
	if bridge == null:
		return {"error": "Android credential store unavailable"}
	error = ""
	var alias := "graffitty.remote." + account.sha256_text()
	var path := preload("res://graffitty/paths.gd").stdpath("data").path_join("credentials").path_join(account.sha256_text() + ".json")
	var store: Variant = _call(_wrap("java.security.KeyStore"), "getInstance", ["AndroidKeyStore"])
	_call(store, "load", [null])
	if not error.is_empty():
		return {"error": error}
	if operation == "delete":
		_call(store, "deleteEntry", [alias])
		if not error.is_empty():
			return {"error": error}
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return {"ok": true}
	if operation == "get" and not FileAccess.file_exists(path):
		return {"password": ""}
	var contains: Variant = _call(store, "containsAlias", [alias])
	if operation == "set" and not bool(contains):
		var builder: Variant = _call(_wrap("android.security.keystore.KeyGenParameterSpec$Builder"), "KeyGenParameterSpec$Builder", [alias, 3])
		_call(builder, "setBlockModes", [PackedStringArray(["GCM"])])
		_call(builder, "setEncryptionPaddings", [PackedStringArray(["NoPadding"])])
		_call(builder, "setKeySize", [256])
		var spec: Variant = _call(builder, "build", [])
		var generator: Variant = _call(_wrap("javax.crypto.KeyGenerator"), "getInstance", ["AES", "AndroidKeyStore"])
		_call(generator, "init", [spec])
		_call(generator, "generateKey", [])
	var key: Variant = _call(store, "getKey", [alias, PackedByteArray()])
	var cipher: Variant = _call(_wrap("javax.crypto.Cipher"), "getInstance", ["AES/GCM/NoPadding"])
	if not error.is_empty() or key == null:
		return {"error": "Cannot unlock Android credential store"}
	if operation == "set":
		_call(cipher, "init", [1, key])
		_call(cipher, "updateAAD", [account.to_utf8_buffer()])
		var encrypted: Variant = _call(cipher, "doFinal", [password.to_utf8_buffer()])
		var iv: Variant = _call(cipher, "getIV", [])
		if not error.is_empty() or not encrypted is PackedByteArray or not iv is PackedByteArray:
			return {"error": "Cannot encrypt saved password"}
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			return {"error": "Cannot save encrypted password"}
		file.store_string(JSON.stringify({"iv": Marshalls.raw_to_base64(iv), "ciphertext": Marshalls.raw_to_base64(encrypted)}))
		file.close()
		if DirAccess.rename_absolute(path + ".tmp", path) != OK:
			return {"error": "Cannot replace encrypted password"}
		return {"ok": true}
	if operation != "get":
		return {"error": "Unknown credential operation"}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Dictionary or not value.get("iv") is String or not value.get("ciphertext") is String:
		return {"error": "Invalid encrypted credential"}
	var params: Variant = _call(_wrap("javax.crypto.spec.GCMParameterSpec"), "GCMParameterSpec", [128, Marshalls.base64_to_raw(value.iv)])
	_call(cipher, "init", [2, key, params])
	_call(cipher, "updateAAD", [account.to_utf8_buffer()])
	var decrypted: Variant = _call(cipher, "doFinal", [Marshalls.base64_to_raw(value.ciphertext)])
	if not error.is_empty() or not decrypted is PackedByteArray:
		return {"error": "Cannot decrypt saved password"}
	return {"password": decrypted.get_string_from_utf8()}


func _wrap(name: String) -> Variant:
	if not error.is_empty():
		return null
	var result: Variant = bridge.wrap(name)
	if bridge.get_exception() != null or result == null:
		error = "Android credential API unavailable"
	return result


func _call(object: Variant, method: String, arguments: Array) -> Variant:
	if not error.is_empty() or object == null:
		return null
	var result: Variant = object.callv(method, arguments)
	if bridge.get_exception() != null:
		error = "Android credential store operation failed"
	return result
