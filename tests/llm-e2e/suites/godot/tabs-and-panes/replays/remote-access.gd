extends "../../../../replay/replay.gd"
var startup_enabled := false

func toggle() -> void:
	for entry in host.menu_entries:
		if entry.label == "Sessions::Remote Access":
			entry.action.call(host)
			await process_frame
			var deadline := Time.get_ticks_msec() + 10000
			while app.remote_access_busy and Time.get_ticks_msec() < deadline:
				await process_frame
			return
	check(false, "Remote Access menu exists")

func play() -> void:
	var startup_deadline := Time.get_ticks_msec() + 10000
	while app.remote_access_busy and Time.get_ticks_msec() < startup_deadline:
		await process_frame
	check(app.remote_access_enabled() == startup_enabled, "Startup respects opt-in configuration")
	var term: Control = host.sessions[host.active_session_id].term
	var pid: int = term.get_shell_pid()
	if not startup_enabled: await toggle()
	if not check(app.remote_access_enabled(), "Menu enables sharing without restart"): return
	var descriptor: String = app.remote_control.connection_file
	var settings: Dictionary = await app.remote_control._request("auth_settings")
	var owner_descriptor: String = settings.result.connection_file
	var token: String = app.remote_control.token
	check(FileAccess.file_exists(descriptor), "Connection descriptor exists while sharing")
	var client := StreamPeerTCP.new()
	check(client.connect_to_host("127.0.0.1", int(app.remote_control.address.get_slice(":", 2))) == OK, "Client starts connection")
	await hold(.15)
	client.poll()
	check(client.get_status() == StreamPeerTCP.STATUS_CONNECTED, "Listener accepts client")
	await toggle()
	client.poll()
	check(not app.remote_access_enabled(), "Menu closes listener immediately")
	check(client.get_status() != StreamPeerTCP.STATUS_CONNECTED, "Stopping sharing disconnects client")
	check(FileAccess.file_exists(owner_descriptor), "Private server descriptor survives disabling network access")
	var private_settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(owner_descriptor))
	check(private_settings.remote == null and str(private_settings.url).begins_with("ipc://"), "Private descriptor removes network credentials when sharing stops")
	if descriptor != owner_descriptor:
		check(not FileAccess.file_exists(descriptor), "Exported network pairing descriptor disappears when sharing stops")
	await toggle()
	check(app.remote_access_enabled(), "Sharing can be restarted")
	check(app.remote_control.token != token, "Restart rotates pairing token")
	check(term.get_shell_pid() == pid, "Local terminal survives sharing changes")
	await toggle()

	var path: String = app.remote_control.auth_path
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var password := "replay-only permanent password"
	var saved: Dictionary = JSON.parse_string(auth.save_settings(path, password, false, "", "", 6))
	check(saved.get("ok", false), "Configure permanent password locally")
	for restart in range(2):
		await toggle()
		check(app.remote_control.token.is_empty(), "Permanent password disables temporary token")
		var remote := preload("res://scenes/remote/RemoteConnection.gd").new()
		app.add_child(remote)
		remote.connect_remote(app.remote_control.address, password)
		var deadline := Time.get_ticks_msec() + 5000
		while not remote.connected and Time.get_ticks_msec() < deadline:
			await wait(.03)
		check(remote.connected, "Permanent password survives sharing restart %d" % restart)
		remote.disconnect_remote()
		remote.queue_free()
		await toggle()
	DirAccess.remove_absolute(path)
