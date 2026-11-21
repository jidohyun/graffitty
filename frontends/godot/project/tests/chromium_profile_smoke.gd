extends "../../../../tests/llm-e2e/replay/replay.gd"


var http := TCPServer.new()
var clients: Array[StreamPeerTCP] = []

func serve_fixture() -> void:
	while http.is_connection_available(): clients.append(http.take_connection())
	for client in clients.duplicate():
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(client)
			continue
		if client.get_available_bytes() > 0:
			client.get_data(client.get_available_bytes())
			var body := "<!doctype html><title>Persistent storage test</title>PROFILE FIXTURE"
			client.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]).to_utf8_buffer())
			clients.erase(client)


func ready_chromium(chromium: Node) -> bool:
	var until := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and chromium.pid > 0 and Time.get_ticks_msec() < until:
		await process_frame
	check(chromium.chromium_ready, "Chromium starts with selected profile")
	return chromium.chromium_ready


func close_chromium(chromium: Node) -> void:
	var runtime: String = chromium.directory
	var process: int = chromium.pid
	host.close_chromium_session(chromium.session_id)
	var until := Time.get_ticks_msec() + 20000
	while OS.execute("/bin/kill", ["-0", str(process)], [], false) == 0 and Time.get_ticks_msec() < until:
		await process_frame
	check(OS.execute("/bin/kill", ["-0", str(process)], [], false) != 0, "Owner's Chromium exits gracefully")
	check(not DirAccess.dir_exists_absolute(runtime), "Runtime is deleted after Chromium exits")


func play() -> void:
	await camera_at_rest()
	# All test storage is isolated from real chromium data.
	var state := OS.get_environment("XDG_STATE_HOME")
	check(not state.is_empty(), "Private runner supplies owner storage")
	if state.is_empty(): return
	check(http.listen(0, "127.0.0.1") == OK, "Private HTTP origin starts")
	process_frame.connect(serve_fixture)
	var chromium: Node = await host.create_chromium_session("about:blank", -1, true, "")
	check(not chromium.persistent_profile, "Default profile is temporary")
	if await ready_chromium(chromium):
		check(chromium.directory.get_file().begins_with("gr-cap-") and DirAccess.dir_exists_absolute(chromium.directory), "Owner reports its private capture runtime directory: " + chromium.directory)
		check(DirAccess.dir_exists_absolute(chromium.profile_directory), "CEF creates isolated profile")
	await close_chromium(chromium)
	var profile := state.path_join("persistent-profile")
	DirAccess.make_dir_recursive_absolute(profile)
	var sentinel := FileAccess.open(profile.path_join("keep-me"), FileAccess.WRITE)
	sentinel.store_string("Existing user data")
	sentinel.close()
	var url := "http://127.0.0.1:%d/" % http.get_local_port()
	chromium = await host.create_chromium_session(url, -1, true, profile)
	check(chromium.persistent_profile, "Explicit profile is persistent")
	if await ready_chromium(chromium):
		check(DirAccess.dir_exists_absolute(profile.path_join("Default")), "CEF uses the explicit profile")
		await hold(0.5)
		var saved: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "localStorage.setItem('profile-test', 'saved'); localStorage.getItem('profile-test')", "returnByValue": true}})
		check(saved.get("result", {}).get("result", {}).get("value") == "saved", "Writes chromium storage")
	await close_chromium(chromium)
	check(FileAccess.get_file_as_string(profile.path_join("keep-me")) == "Existing user data", "Existing profile contents survive close")
	check(DirAccess.dir_exists_absolute(profile.path_join("Default")), "Chromium data survives close")
	# Explicit operations can reuse a server-side profile.
	chromium = await host.create_chromium_session(url, -1, true, profile)
	check(chromium.persistent_profile and chromium.profile_directory == profile, "Explicit request reuses persistent profile")
	if await ready_chromium(chromium):
		await hold(0.5)
		var restored: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "localStorage.getItem('profile-test')", "returnByValue": true}})
		check(restored.get("result", {}).get("result", {}).get("value") == "saved", "Chromium storage survives restart")
	await close_chromium(chromium)
	check(FileAccess.file_exists(profile.path_join("keep-me")), "Reused profile survives another close")
	process_frame.disconnect(serve_fixture)
	http.stop()
