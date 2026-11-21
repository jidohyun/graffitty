extends "terminal-tools.gd"

func until(condition: Callable, label: String, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec()+int(seconds*1000)
	while not condition.call() and Time.get_ticks_msec()<deadline: await process_frame
	return check(condition.call(), label)

func picture(owner: Node, name: String) -> void:
	RenderingServer.force_draw(false)
	owner.get_window().get_texture().get_image().save_png(directory.path_join(name+".png"))

func write_marker(owner: Node, name: String, color: int) -> void:
	owner.active_terminal().send_text("[Console]::Write(([char]27)+'["+str(color)+"m'+([char]27)+'[2J'+([char]27)+'[H'+('"+name+"'))\r")
	await until(func():return Array(str(owner.active_terminal().get_text(false).text).split("\n")).any(func(line):return line.strip_edges()==name), "Real PTY completes "+name)
	await hold(.3)

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	root.gui_embed_subwindows=false
	var releases: Array[Callable]=[]
	releases.append(host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	var original: Node=host
	var original_pid: int=host.active_terminal().get_shell_pid()
	var original_key: String=host.pane_focus
	await host.create_native_window()
	var local: Node
	for candidate in app.hosts:
		if candidate!=host:local=candidate
	if not check(local!=null,"Separate local window opens"):return
	releases.append(local.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	await until(func():return local.active_terminal()!=null and local.active_terminal().get_shell_pid()>0,"Second real local shell starts")
	var local_pid: int=local.active_terminal().get_shell_pid()
	var local_id: int=local.active_session_id
	local.workspace_view.overview=true
	local.workspace_view.navigation_zoom=.7
	local.workspace_view.navigation_center=Vector2(880,460)
	local.workspace_view._apply_navigation()
	await write_marker(original,"LOCAL_RED_DONE",41)
	await write_marker(local,"LOCAL_BLUE_DONE",44)
	await hold(.8)
	overlay.hide()
	picture(original,"window-one-red")
	picture(local,"window-two-blue")
	var descriptor: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_REMOTE_DESCRIPTOR")))
	var remote: Dictionary=descriptor.remote
	var dialog: Node = app.show_servers(local.get_parent())
	dialog._edit({})
	dialog.editor.endpoint.text = remote.url
	dialog.editor.token.text = remote.token
	dialog.editor.remember.button_pressed = false
	dialog._save(false)
	var client: Node
	await process_frame
	for candidate in local.get_window().get_children():
		if "local_return" in candidate and candidate.local_return!=null:client=candidate
	# The parked host now belongs to the application root. Locate its descendant context.
	if client==null:
		for candidate in get_nodes_in_group("shared_presentations"):
			if candidate.local_return!=null and candidate.local_return.client==local.get_parent():client=candidate
	if not check(client!=null,"Servers manager parks the local presentation"):return
	if not await until(func():return client.host!=null and client.connection.connected,"Independent remote owner authenticates and renders"):return
	var remote_host: Node=client.host
	releases.append(remote_host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	var remote_pid: int=remote_host.active_terminal().get_shell_pid()
	var remote_id: int=remote_host.active_session_id
	check(remote_pid>0 and remote_pid!=local_pid and remote_pid!=original_pid,"Remote shell has independent actual PID")
	await write_marker(original,"LOCAL_DURING_REMOTE",41)
	await write_marker(remote_host,"REMOTE_GREEN_DONE",42)
	check(not "REMOTE_GREEN_DONE" in str(original.active_terminal().get_text(false).text),"Remote input cannot route to local sibling")
	picture(remote_host,"remote-window")
	await remote_host.create_native_window()
	var child: Node
	for candidate in app.hosts:
		if candidate!=original and candidate!=remote_host:child=candidate
	if not check(child!=null,"Remote child window opens with inherited local return"):return
	releases.append(child.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	if not await until(func():return child.get_parent().connection.connected and not child.get_parent().connection.epoch.is_empty(),"Remote child authenticates before window operations"):return
	var child_id: int=child.active_session_id
	var child_pid: int=child.active_terminal().get_shell_pid()
	await until(func():return child_pid>0 or child.active_terminal().get_shell_pid()>0,"Remote child owns real shell")
	child_pid=child.active_terminal().get_shell_pid()
	child.workspace_view.overview=true
	child.workspace_view.navigation_zoom=.8
	child.workspace_view.navigation_center=Vector2(700,400)
	child.workspace_view._apply_navigation()
	var remote_ref: WeakRef = weakref(remote_host)
	check(await app.move_workspace(remote_host,child,remote_id),"Move original remote tab into child window")
	child.select_workspace(child_id)
	if not await until(func():return remote_ref.get_ref()==null or remote_ref.get_ref().is_queued_for_deletion(),"Moving the last remote tab retires its source window"):return
	await hold(3.0)
	check(original.active_terminal().get_shell_pid()==original_pid and original.pane_focus==original_key,"Remote transfer leaves unrelated local window and focus intact")
	check(child.active_session_id==child_id and child.active_terminal().get_shell_pid()==child_pid,"Selecting the original child tab restores its focus and shell")
	check(child.sessions.has(remote_id) and child.sessions[remote_id].term.get_shell_pid()==remote_pid,"Remote transfer retains original pane identity and shell")
	check(absf(child.workspace_view.navigation_zoom-.8)<.001 and child.workspace_view.navigation_center.distance_to(Vector2(700,400))<.01,"Selecting the original child tab restores its camera")
	picture(child,"remote-child-transfer")
	FileAccess.open(directory.path_join("process-watch.json"),FileAccess.WRITE).store_string(JSON.stringify({"remote":{"pid":remote_pid,"exited":false},"remote_child":{"pid":child_pid,"exited":false},"parked_local":{"pid":local_pid,"exited":false}}))
	var helper: String=get_script().resource_path.get_base_dir().path_join("../../../../../platform/windows/windows_process_receipt.py").simplify_path()
	OS.create_process(OS.get_environment("GRAFFITTY_INPUT_PYTHON"),PackedStringArray([helper,directory]),false)
	if not await until(func():return FileAccess.file_exists(directory.path_join("process-watch-ready")),"Remote and parked local process handles retained before detach"):return
	var target_window: Window=child.get_window()
	child.request_close_window()
	if not await until(func():return child.close_dialog!=null and child.close_dialog.visible,"Remote window close exposes the detach choice"):return
	check(child.close_dialog.get_cancel_button().has_focus(),"Remote close starts with Cancel focus")
	check(not child.close_dialog.get_ok_button().get_parent().get_children().any(func(button): return button is Button and button.text == "Kill Server"), "Remote close never offers server shutdown")
	await hold(.2)
	RenderingServer.force_draw(false)
	child.close_dialog.get_texture().get_image().save_png(directory.path_join("remote-close-choice.png"))
	child.close_dialog.get_ok_button().pressed.emit()
	await hold(.5)
	FileAccess.open(directory.path_join("process-watch-close"),FileAccess.WRITE).close()
	if await until(func():return FileAccess.file_exists(directory.path_join("process-receipt.json")),"Remote detach process receipt arrives"):
		check(JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("process-receipt.json"))).get("status")=="PASS","Remote close dialog detach preserves both remote shells and parked local shell")
	check(local.get_window()==target_window and local.active_session_id==local_id and local.active_terminal().get_shell_pid()==local_pid,"Child disconnect returns original local tab and same shell in child window")
	check(absf(local.workspace_view.navigation_zoom-.7)<.001 and local.workspace_view.navigation_center.distance_to(Vector2(880,460))<.01,"Inherited return restores original local camera")
	await write_marker(local,"RETURNED_LOCAL_DONE",44)
	check(original.active_terminal().get_shell_pid()==original_pid,"Unrelated local shell survives remote return")
	picture(local,"returned-local-window")
	FileAccess.open(directory.path_join("trace.json"),FileAccess.WRITE).store_string(JSON.stringify({"original_pid":original_pid,"local_pid":local_pid,"remote_pid":remote_pid,"remote_child_pid":child_pid}))
