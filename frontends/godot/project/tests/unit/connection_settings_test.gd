extends "res://tests/unit/test_case.gd"
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")


## Saved connections are one per server address.
func address(server: String) -> String:
	return "ws://%s.example.test:7183" % server


func saved(server: String) -> Dictionary:
	for entry in Authentication.saved_connections():
		if entry.url == address(server):
			return entry
	return {}


func test_loaded_stream_preferences_can_be_saved_again() -> void:
	for stream in [{"max_height": 0, "fps": 0, "bitrate_kbps": 0}, {"max_height": 1440, "fps": 30, "bitrate_kbps": 12000}]:
		var workspace := "roundtrip-%d" % stream.max_height
		var settings := {"url": address(workspace), "chromium_stream": stream}
		expect(Authentication.save_connection(settings).is_empty(), "Initial integer settings save")
		for cycle in 3:
			var loaded := saved(workspace)
			expect(not loaded.is_empty(), "Saved settings load")
			if loaded.is_empty(): return
			expect(typeof(loaded.chromium_stream.bitrate_kbps) == TYPE_FLOAT, "Exercise Godot JSON's integer-as-float round trip")
			loaded.hostname = "server-%d" % cycle
			var error := Authentication.save_connection(loaded)
			expect(error.is_empty(), "Resaving the manager's loaded settings succeeds: " + error)
			expect(saved(workspace).hostname == loaded.hostname, "The latest hostname is persisted")
			for field in stream:
				expect(saved(workspace).chromium_stream[field] == stream[field], "Auto and explicit quality values remain unchanged")


func test_bulk_save_preserves_other_loaded_connections() -> void:
	for workspace in ["keep-quality", "remove-quality"]:
		var settings := {"url": address(workspace), "chromium_stream": {"max_height": 720, "fps": 60, "bitrate_kbps": 0}}
		expect(Authentication.save_connection(settings).is_empty(), "Create saved workspace")
	var remaining := Authentication.saved_connections().filter(func(entry): return entry.url != address("remove-quality"))
	var error := Authentication._save(remaining)
	expect(error.is_empty(), "Removing one workspace resaves the other loaded entries: " + error)
	expect(saved("remove-quality").is_empty(), "The removed workspace stays removed")
	var kept := saved("keep-quality")
	expect(not kept.is_empty() and kept.chromium_stream.max_height == 720 and kept.chromium_stream.fps == 60 and kept.chromium_stream.bitrate_kbps == 0, "Other workspaces retain their quality preferences")


func test_invalid_ui_numbers_never_overwrite_saved_connections() -> void:
	var valid := {"url": address("validate-quality"), "chromium_stream": {"max_height": 1080, "fps": 60, "bitrate_kbps": 8000}}
	expect(Authentication.save_connection(valid).is_empty(), "Create valid saved preferences")
	var path := Authentication.connection_path()
	var before := FileAccess.get_file_as_string(path)
	for invalid in [["max_height", -1.0], ["fps", .5], ["fps", 61.0], ["bitrate_kbps", 200001.0], ["fps", INF], ["fps", NAN], ["fps", true], ["fps", "0"], ["obsolete_limit", 0]]:
		var changed := saved("validate-quality")
		changed.chromium_stream[invalid[0]] = invalid[1]
		expect(not Authentication.save_connection(changed).is_empty(), "Reject malformed or out-of-range stream preference")
		expect(FileAccess.get_file_as_string(path) == before, "Failed single-entry saves leave the file unchanged")
		var batch := Authentication.saved_connections()
		batch.append(changed)
		expect(not Authentication._save(batch).is_empty(), "Bulk saves enforce the same validation")
		expect(FileAccess.get_file_as_string(path) == before, "Failed bulk saves leave every connection unchanged")


func test_saved_document_still_requires_integer_limits() -> void:
	expect(Authentication.save_connection({"url": address("strict-document")}).is_empty(), "Create a valid document before corruption")
	var original := FileAccess.get_file_as_string(Authentication.connection_path())
	var malformed := '[{"name":"","url":"ws://example.test:7183","workspace":"main","chromium_stream":{"fps":0.0}}]'
	var file := FileAccess.open(Authentication.connection_path(), FileAccess.WRITE)
	file.store_string(malformed)
	file.close()
	expect(Authentication.read_connections().has("error"), "UI conversion does not relax the persisted schema")
	expect(not Authentication.save_connection({"url": address("strict-document")}).is_empty(), "Corrupt saved data is not overwritten by an upsert")
	expect(FileAccess.get_file_as_string(Authentication.connection_path()) == malformed, "The invalid document remains untouched")
	file = FileAccess.open(Authentication.connection_path(), FileAccess.WRITE)
	file.store_string(original)
	file.close()
