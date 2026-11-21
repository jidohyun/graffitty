extends SceneTree
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
const Card := preload("res://scenes/remote/ServerCard.gd")
var failures: Array[String] = []
var app: Node
var directory := ""

func _initialize() -> void:
	Background.install(self)
	run.call_deferred()

func check(ok: bool, message: String) -> bool:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures.append(message)
	return ok

func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func picture(control: Window, name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await process_frame
	RenderingServer.force_draw(false)
	control.get_texture().get_image().save_png(directory.path_join(name + ".png"))

func run() -> void:
	root.size = Vector2i(1200, 800)
	directory = OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	app = root.get_node("TerminalApplication")
	var local: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(local)
	if not check(await until(func(): return local.host != null and local.host.active_terminal() != null), "Local workspace opens"):
		quit(1); return
	if "--scenario=startup" in OS.get_cmdline_user_args():
		check(await until(func(): return root.get_node_or_null("Servers") != null and root.get_node("Servers").visible), "Saved startup preference opens Servers after relaunch")
		check(local.connection.connected and local.host.active_terminal().get_shell_pid() > 0, "Startup manager preserves usable local workspace")
		finish(); return
	check(root.get_node_or_null("Servers") == null, "Desktop opens directly by default")
	var host: Node = local.host
	var pid: int = host.active_terminal().get_shell_pid()
	var id: int = host.active_session_id
	var window_id := root.get_window_id()
	host.workspace_view.overview = true
	host.workspace_view.navigation_zoom = .75
	host.workspace_view.navigation_center = Vector2(700, 400)
	host.workspace_view._apply_navigation()
	var menus: Array = host.menu_entry_specs().filter(func(entry): return entry.label == "Sessions::Servers…")
	check(menus.size() == 1, "Desktop exposes one Servers menu action")
	menus[0].action.call(host)
	var manager: Node = root.get_node("Servers")
	check(manager.visible and local.connection.connected, "Manager opens without detaching local shells")
	check(manager.chooser.get_script() == preload("res://scenes/remote/ServerBrowserPage.gd"), "Desktop uses the shared Android server browser page")
	manager.chooser.add_server.pressed.emit()
	check(manager.form.visible and not manager.chooser.visible, "Add server opens the shared editor page instead of split-pane details")
	manager.editor.endpoint.text = "https://example.invalid"
	manager.editor.token.text = "fixture"
	manager._save(false)
	check(not manager.editor.form_status.text.is_empty() and manager.client == local, "Invalid URL stays in editor without parking local workspace")
	manager._cancel_edit()
	manager.hide()
	menus[0].action.call(local.host)
	check(manager.visible and host.active_terminal().get_shell_pid() == pid, "Sessions menu reopens the same manager")
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_TEST_REMOTE_DESCRIPTOR")))
	var remote: Dictionary = descriptor.remote
	manager._edit({})
	manager.editor.label.text = "Build server"
	manager.editor.endpoint.text = remote.url
	manager.editor.token.text = remote.token
	manager.editor.remember.button_pressed = false
	manager._save(false)
	if not check(await until(func(): return manager.client != local and manager.client.connection.connected and manager.client.host != null), "Saved server connects in this window"):
		finish(); return
	var client: Node = manager.client
	await process_frame
	check(client.local_return.client == local and root.get_window_id() == window_id, "Remote view retains the exact local return context and native window")
	var saved := Authentication.saved_connections()
	check(saved.size() == 1 and saved[0].name == "Build server" and not saved[0].has("token") and not saved[0].remember, "Server metadata persists without plaintext password")
	menus[0].action.call(client.host)
	await picture(manager, "servers")
	check(manager.cards.size() == 1 and manager.cards[0].card is Card, "Saved servers use the same cards as Android")
	manager._edit(manager.selected)
	manager.editor.token.text = "unsubmitted"
	manager._cancel_edit()
	check(client.connection.connected and manager.editor.token.text.is_empty(), "Cancel editor clears password and preserves connection")
	manager._open(true)
	check(await until(func(): return app.hosts.size() == 2), "Open in new window creates a second remote presentation")
	var child: Node
	for candidate in app.hosts:
		if candidate != client.host: child = candidate.get_parent()
	if is_instance_valid(child):
		check(child.get_window() != root and child.local_return == null, "New window has an independent presentation")
		child.detach()
		await process_frame
		check(client.connection.connected, "Closing new window keeps the first connection alive")
	manager._return_local()
	await process_frame
	check(local.host == host and host.active_terminal().get_shell_pid() == pid and host.active_session_id == id, "Return restores the original local shell and tab")
	check(is_equal_approx(host.workspace_view.navigation_zoom, .75), "Return restores local navigation")
	check(client.connection.connected, "Returning locally retains the remote connection in Sessions")
	menus[0].action.call(local.host)
	manager._edit(saved[0])
	manager.editor.token.text = "wrong fixture password"
	manager._save(false)
	check(await until(func(): return manager.client != local and not manager.client.connection.enabled), "Bad password is rejected")
	check(manager.visible and Authentication.saved_connections().size() == 1, "Authentication failure retains server and exposes recovery")
	manager._edit(saved[0])
	manager.editor.token.text = remote.token
	manager.editor.remember.button_pressed = false
	manager._save(false)
	check(await until(func(): return manager.client.connection.connected and manager.client.host != null), "Correct password recovers without a duplicate saved server")
	manager.present(manager.client)
	manager.selected = saved[0]
	manager._forget()
	check(Authentication.saved_connections().is_empty() and manager.client.connection.connected, "Forget preserves the open remote workspace")
	manager.client.connection.connect_remote(remote.url, remote.token)
	check(await until(func(): return manager.client.connection.connected), "Forgotten server can reconnect in its existing window: " + manager.client.connection.status_source)
	await process_frame
	check(Authentication.saved_connections().is_empty(), "Reconnect does not recreate a forgotten server")
	manager._return_local()
	await process_frame
	manager.present(local)
	check(local.connection.connected, "Forget and reconnect preserve the parked local workspace")
	manager.startup.button_pressed = true
	var preferences := ConfigFile.new()
	check(preferences.load(app.presentation_path()) == OK and preferences.get_value("servers", "show_at_startup") == true, "Startup preference persists")
	finish()

func finish() -> void:
	# Let the native guard sample the short startup-only scenario as well.
	if DisplayServer.get_name() != "headless": await create_timer(.8).timeout
	print("DESKTOP_SERVERS_PASS" if failures.is_empty() else "DESKTOP_SERVERS_FAIL " + str(failures))
	quit(0 if failures.is_empty() else 1)
