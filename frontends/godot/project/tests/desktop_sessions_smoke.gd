extends SceneTree
## test_desktop_sessions.py owns all three servers and their live processes.
var failures: Array[String] = []
const Model := preload("res://scenes/session/SessionsList.gd")

func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)

func wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "0")
	root.size = Vector2i(1280, 800)
	var entry: String = ProjectSettings.get_setting("application/run/main_scene")
	check(entry == "res://scenes/terminal.tscn", "Remote arguments use the normal desktop entry")
	var local: Node = load(entry).instantiate()
	root.add_child(local)
	var app: Node = root.get_node("TerminalApplication")
	if not await wait_for(func(): return app.session_hosts().size() == 3 and app.session_hosts().all(func(h): return h.active_terminal() != null and h.active_terminal().get_shell_pid() > 0)):
		check(false, "Local and two remote computers attach in the normal app")
		quit(1)
		return
	var groups := Model.collect(app.session_hosts(), [])
	check(groups.size() == 3 and groups[0].local and groups[0].connected, "This Computer stays first beside both connected remotes")
	check(app.hosts.size() == 1, "All connections share one normal desktop window")
	var pids := {}
	for group in groups:
		check(not group.sessions.is_empty(), "Each computer lists its actual server sessions")
		pids[group.id] = group.host.active_terminal().get_shell_pid()
		check(not group.host.get_parent().federated, "Every computer uses an ordinary desktop presentation")
	# Exercise the actual Sessions panel action and its camera restoration.
	await app.mods._select_session(groups[0].sessions[0], groups[0])
	await process_frame
	var local_view: Node = local.host.workspace_view
	local_view.overview = true
	local_view.navigation_zoom = .7
	local_view.navigation_center = Vector2(880, 460)
	local_view._apply_navigation()
	for index in [1, 2, 0, 2, 1, 0]:
		groups = Model.collect(app.session_hosts(), [])
		var group: Dictionary = groups[index]
		await app.mods._select_session(group.sessions[0], group)
		await process_frame
		check(app.hosts.size() == 1 and app.hosts[0] == group.host, "Sessions selects the computer in the existing window")
		check(groups.all(func(g): return g.peer.connected), "Switching computers keeps every transport connected")
		check(group.host.active_terminal().get_shell_pid() == pids[group.id], "Switching preserves the live shell PID")
	check(is_equal_approx(local_view.navigation_zoom, .7) and local_view.navigation_center.is_equal_approx(Vector2(880, 460)), "Local pan and zoom survive repeated computer switches")
	# A deliberate remote disconnect still returns locally without shutting down
	# that server or removing the other remote connection.
	groups = Model.collect(app.session_hosts(), [])
	var remote: Node = groups[1].host.get_parent()
	var other: Node = groups[2].peer
	app.present_desktop_client(remote)
	remote.detach()
	await process_frame
	check(app.hosts.has(local.host) and local.connection.connected, "Explicit disconnect restores the local presentation")
	check(other.connected, "Disconnect affects only the chosen remote connection")
	# The Python owner verifies these actual PIDs. Godot's Unix helper only
	# accepts its own child processes, whereas these belong to three servers.
	print("DESKTOP_SHELL_PIDS " + JSON.stringify(pids.values()))
	check(Model.collect(app.session_hosts(), [])[0].local, "Local computer remains the first group after disconnect")
	app.retire_empty_host(local.host, true)
	await process_frame
	check(app.hosts.size() == 1 and app.hosts[0].get_parent().connection == other, "Closing the local presentation reveals a retained remote instead of quitting")
	groups = Model.collect(app.session_hosts(), [], true)
	check(groups[0].local and groups[0].peer == null, "This Computer remains available when its last view closes")
	app.mods._publish_sessions()
	app.mods.run(app.hosts[0], "NewSession", {"server": "shared://local"})
	check(await wait_for(func(): return app.session_hosts().any(func(h): return h.get_parent().settings.get("shared_local", false) and h.active_terminal() != null)), "This Computer can open a new local session from the remote presentation")
	groups = Model.collect(app.session_hosts(), [], true)
	check(groups[0].local and groups[0].connected, "The local server resumes its first position with real sessions")
	for client in get_nodes_in_group("shared_presentations"): client.connection.disconnect_remote()
	await create_timer(.3).timeout
	print("DESKTOP_SESSIONS_%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)
