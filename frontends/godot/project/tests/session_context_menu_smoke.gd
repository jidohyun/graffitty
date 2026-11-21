extends SceneTree
## Owned local/remote fixtures are supplied by test_session_context_menu.py.
const ContextMenu := preload("res://scenes/session/SessionContextMenu.gd")
const HostActions := preload("res://scenes/HostActions.gd")
const KillDialog := preload("res://scenes/session/KillSessionDialog.gd")
const NameEdit := preload("res://scenes/session/SessionNameEdit.gd")
var failures: Array[String] = []

func check(ok: bool, message: String) -> bool:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)
	return ok

func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "0")
	root.size = Vector2i(1280, 800)
	var remote := OS.get_environment("GRAFFITTY_TEST_REMOTE_DESCRIPTOR")
	var client: Node
	if remote.is_empty():
		client = load("res://scenes/terminal.tscn").instantiate()
		client.launch_args = PackedStringArray(["--workspace=main"])
	else:
		var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(remote))
		client = load("res://scenes/remote/RemoteClient.gd").new()
		client.managed = true
		client.settings = {"url": descriptor.url, "token": descriptor.token, "workspace": "main", "transient": true}
	root.add_child(client)
	if not check(await until(func(): return is_instance_valid(client.host) and client.host.active_terminal() != null), "Client attaches to its owned server"):
		quit(1); return
	var host: Node = client.host
	var peer: Node = client.connection
	var original: String = peer.workspace
	var original_pid: int = host.active_terminal().get_shell_pid()
	var created: Dictionary = await peer.request_action("session_new", {"name": "menu-target"})
	check(created.get("type") != "error", "Target session is created on the server")
	var target: String = peer.workspace
	await peer.request_action("session_switch", {"name": original})
	check(await until(func(): return host.active_terminal() != null and host.active_terminal().get_shell_pid() == original_pid), "Original session remains the active view")
	var app: Node = host.application
	if DisplayServer.get_name() == "headless": root.gui_embed_subwindows = true
	var panel: Window = preload("res://scenes/mods/PanelWindow.gd").open(host, "sessions")
	app.mods._publish_sessions()
	app.mods.run(host, "SessionContextMenu", {"server": peer.url, "session": target}, panel)
	await process_frame
	var menu_owner: Window = panel.view.get_window()
	var menu: PopupMenu = menu_owner.get_node("SessionContextMenu")
	var presentation: Window = preload("res://scenes/PopupChrome.gd").presentation(menu)
	check(await until(func(): return presentation.visible), "Session menu opens from the Sessions panel")
	await create_timer(.2).timeout
	check(presentation.size.x / presentation.content_scale_factor >= presentation._content_width() + 15, "Menu fits its translated labels outside the docked panel's hidden window")
	check(peer.workspace == original, "Opening a menu never switches the session")
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not evidence.is_empty() and DisplayServer.get_name() != "headless":
		await create_timer(.2).timeout
		RenderingServer.force_draw(false)
		presentation.get_texture().get_image().save_png(evidence.path_join("session-menu.png"))
	preload("res://scenes/PopupChrome.gd").close(menu)
	menu.id_pressed.emit(ContextMenu.Action.RENAME)
	await process_frame
	var rename := panel.view.get_node_or_null("SessionNameEdit") as NameEdit
	if not check(rename != null and rename.has_focus(), "Rename focuses an editor inside the sessions panel"):
		quit(1); return
	var letter := InputEventKey.new()
	letter.keycode = KEY_D
	letter.unicode = "d".unicode_at(0)
	letter.pressed = true
	menu_owner.push_input(letter, true)
	check(rename.text == "d", "Typing immediately replaces the selected session name")
	if OS.get_name() == "macOS" and DisplayServer.get_name() != "headless":
		check(rename.get_menu().is_native_menu(), "macOS presents the editor menu with native placement and shortcuts")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	menu_owner.push_input(escape, true)
	await process_frame
	check(not is_instance_valid(rename), "Escape dismisses the draft")
	menu.id_pressed.emit(ContextMenu.Action.RENAME)
	await process_frame
	rename = panel.view.get_node("SessionNameEdit")
	check(rename.text == "menu-target", "Escape leaves the name unchanged")
	rename.text = "Renamed fixture"
	var rename_id := rename.get_instance_id()
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	menu_owner.push_input(enter, true)
	await until(func(): return not is_instance_id_valid(rename_id))
	check(await until(func(): return peer.available_sessions.any(func(row): return row.id == target and row.name == "Renamed fixture")), "Rename affects the clicked inactive session")
	check(peer.workspace == original, "Rename preserves the current session")
	menu.id_pressed.emit(ContextMenu.Action.RENAME)
	await process_frame
	rename = panel.view.get_node("SessionNameEdit")
	rename.text = "Click saved"
	var outside_button := Button.new()
	menu_owner.add_child(outside_button)
	outside_button.size = Vector2(40, 30)
	var outside := InputEventMouseButton.new()
	outside.button_index = MOUSE_BUTTON_LEFT
	outside.pressed = true
	outside.position = outside_button.get_global_rect().get_center()
	menu_owner.push_input(outside, true)
	outside.pressed = false
	menu_owner.push_input(outside, true)
	outside_button.queue_free()
	check(await until(func(): return peer.available_sessions.any(func(row): return row.id == target and row.name == "Click saved")), "An outside click saves the draft")
	menu.id_pressed.emit(ContextMenu.Action.KILL)
	await process_frame
	var confirmation := find_confirmation(menu_owner)
	if not check(confirmation != null, "Kill opens confirmation instead of acting immediately"):
		quit(1); return
	check(confirmation.get_cancel_button().has_focus(), "Confirmation starts on Cancel")
	check(confirmation.tr("The server will stay running.") in confirmation.dialog_text, "A sibling session keeps the server running: " + confirmation.dialog_text)
	var confirmation_id := confirmation.get_instance_id()
	confirmation.canceled.emit()
	await until(func(): return not is_instance_id_valid(confirmation_id))
	await peer.request_action("sync")
	check(peer.available_sessions.any(func(row): return row.id == target), "Cancel preserves the target session")
	menu.id_pressed.emit(ContextMenu.Action.KILL)
	await process_frame
	confirmation = find_confirmation(menu_owner)
	await confirmation._kill()
	check(await until(func(): return not peer.available_sessions.any(func(row): return row.id == target)), "Confirmed kill removes exactly the selected session")
	check(await until(func(): return peer.connected and peer.workspace == original and host.active_terminal() != null and host.active_terminal().get_shell_pid() == original_pid), "The server, active session and original shell survive")
	var stale: Dictionary = await peer.request_action("session_kill", {"name": target})
	check(stale.get("type") == "error", "A stale stable ID cannot kill another session")
	var synced: Dictionary = await peer.request_action("sync")
	check(synced.get("type") == "ack" and peer.available_sessions.size() == 1, "Server remains usable after killing the inactive session")
	var original_tab: int = host.workspace_layout.active
	host.create_session()
	if not check(await until(func(): return host.workspace_layout.active != original_tab), "Temporary tab opens in the same session"):
		quit(1); return
	var temporary_tab: int = host.workspace_layout.active
	check(HostActions.run(host, "CloseTab"), "CloseTab runs on the active tab")
	if host.close_dialog != null: host.close_dialog.get_ok_button().pressed.emit()
	check(await until(func(): return host.workspace_layout.tab(temporary_tab).is_empty() and host.close_dialog == null), "CloseTab removes the temporary tab")
	check(peer.workspace == original and host.active_terminal().get_shell_pid() == original_pid, "CloseTab keeps the session and its other tab running")
	if DisplayServer.get_name() != "headless":
		var narrow := Window.new()
		narrow.size = Vector2i(100, 200)
		narrow.content_scale_factor = root.content_scale_factor
		root.add_child(narrow)
		narrow.show()
		var floating_menu := ContextMenu.open(narrow, host, peer, original, "main")
		var floating: Window = preload("res://scenes/PopupChrome.gd").presentation(floating_menu)
		await until(func(): return floating.visible)
		await create_timer(.2).timeout
		check(floating.size.x > narrow.size.x and floating.size.x / floating.content_scale_factor >= floating._content_width() + 15, "Native menu fits full labels even when its floating panel is narrow")
		var bounds := DisplayServer.screen_get_usable_rect(narrow.current_screen)
		check(bounds.encloses(Rect2i(floating.position, floating.size)), "Native menu stays on its screen")
		preload("res://scenes/PopupChrome.gd").close(floating_menu)
		narrow.queue_free()
		await process_frame
	# Killing the session this window displays shows another one in place.
	var window := host.get_window()
	var fallback: Dictionary = await peer.request_action("session_new", {"name": "fallback-target"})
	check(fallback.get("type") != "error", "Fallback session is created on the server")
	var fallback_id: String = peer.workspace
	check(await until(func(): return host.active_terminal() != null and host.active_terminal().get_shell_pid() != original_pid), "Fallback session shows its own shell")
	var fallback_pid: int = host.active_terminal().get_shell_pid()
	await peer.request_action("session_switch", {"name": original})
	check(await until(func(): return peer.workspace == original and is_instance_valid(client.host) and client.host.active_terminal() != null and client.host.active_terminal().get_shell_pid() == original_pid), "Original session is displayed again")
	var active_host: Node = client.host
	var action_peer: Node = preload("res://scenes/session/LiveSessionMenu.gd").transport(active_host)
	check(action_peer != null and action_peer.workspace == original and action_peer.connected, "The active host routes to the displayed session")
	check(active_host.close_dialog == null, "No other close dialog is pending")
	check(HostActions.run(active_host, "CloseSession"), "CloseSession runs on the active session")
	await process_frame
	confirmation = active_host.close_dialog as KillDialog
	if not check(confirmation != null and confirmation.target == original, "CloseSession confirms the displayed session"):
		quit(1); return
	await confirmation._kill()
	check(await until(func(): return peer.workspace == fallback_id and is_instance_valid(client.host) and client.host.active_terminal() != null and client.host.active_terminal().get_shell_pid() == fallback_pid), "Killing the displayed session switches this window to the remaining session")
	check(is_instance_valid(client) and is_instance_valid(window) and window.visible and peer.connected, "The window and its connection stay open")
	if OS.get_name() != "Windows":
		check(await until(func(): return OS.execute("/bin/kill", ["-0", str(original_pid)], [], false) != 0), "The killed session's shell exits")
	check(await until(func(): return peer.available_sessions.size() == 1), "The server publishes the final session")
	var final_warning: String = client.host.session_end_warning([client.host.active_session_id])
	var expected: String = client.host.tr("This is the server’s last session. Closing it will also stop the server.") if remote.is_empty() else client.host.tr("The server will stay running.")
	check(expected in final_warning, "The last-pane warning reflects the server's shutdown policy: " + final_warning)
	if remote.is_empty() and failures.is_empty():
		# Killing the last local session stops the server; with nothing left
		# to show, the application then quits by itself.
		print("SESSION_CONTEXT_MENU_PASS")
		await peer.request_action("session_kill", {"name": fallback_id})
		await create_timer(8.0).timeout
		check(false, "Killing the last local session quits the application")
		quit(1); return
	peer.disconnect_remote()
	await create_timer(.3).timeout
	print("SESSION_CONTEXT_MENU_%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)

func find_confirmation(owner: Node) -> KillDialog:
	for node in owner.get_children():
		if node is KillDialog and not node.is_queued_for_deletion(): return node
	return null
