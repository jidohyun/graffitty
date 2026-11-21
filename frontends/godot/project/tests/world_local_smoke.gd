extends "../../../../tests/llm-e2e/replay/replay.gd"
## A renderer choice survives owner layout updates, new tabs, and legacy metadata.

func play() -> void:
	await open_tabs(1)
	await camera_at_rest()
	if not await open_bistro(): return
	var bistro: Node = host.world
	var path: String = host.current_plugin
	var client: Node = host.get_parent()
	var connection: Node = host.session_backend.connection
	# Create immediately, with earlier layout edits still allowed to be pending.
	# No server acknowledgement of the world is needed, nor is a world reload.
	for _index in 3: host.create_session()
	var deadline := Time.get_ticks_msec() + 10000
	var kept_world := true
	while (host.get_tabs().size() < 4 or host.session_backend.work_pending()) and Time.get_ticks_msec() < deadline:
		await process_frame
		kept_world = kept_world and host.world == bistro and host.current_plugin == path
	check(host.get_tabs().size() == 4, "Rapid creation makes three new tabs")
	check(kept_world and host.world == bistro, "New tabs keep Bistro without any intervening Flat frame or reload")
	await camera_at_rest()
	for tab in connection.topology.tabs:
		check(not tab.has("plugin"), "Server topology contains no renderer choice")
	for settings in connection.topology.workspace_state.tabs.values():
		check(not settings.has("world"), "Server tab settings contain no world path")
	# An older running owner may still send a world field. Receiving it must
	# neither choose a local renderer nor generate a write to erase the field.
	var legacy: Dictionary = connection.topology.duplicate(true)
	for tab in legacy.tabs: tab.plugin = "flat-2d"
	for settings in legacy.workspace_state.tabs.values(): settings.world = "flat-2d"
	connection.topology = legacy
	connection.changed.emit()
	await hold(0.2)
	check(host.world == bistro and host.current_plugin == path, "Legacy owner world fields cannot replace this frontend's Bistro")
	for index in [0, 3, 1]:
		await select_tab(index)
		check(host.world == bistro, "Switching tabs keeps the window's world")
	await camera_at_rest()
	var captured: Dictionary = await app.checkpoints.capture()
	check(captured.has("result") and captured.result.windows[0].plugin == path, "Frontend session snapshot retains the world locally")
	# Recreating the presentation after a reconnect retains its local choice.
	client._release_host()
	client.topology_signature = ""
	client._refresh()
	host = client.host
	check(is_instance_valid(host) and host.current_plugin == path, "Recreating the frontend preserves its own world despite legacy owner fields")
