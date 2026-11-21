extends "remote-window-return.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	root.gui_embed_subwindows=false
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	var focused: String=host.pane_focus
	var active: int=host.workspace_layout.active
	var pid: int=host.active_terminal().get_shell_pid()
	await host.create_native_window()
	var other: Node
	for candidate in app.hosts:
		if candidate!=host:other=candidate
	if not check(other!=null,"Local sibling created for tab transfer"):return
	var other_id: int=other.active_session_id
	var other_pid: int=other.active_terminal().get_shell_pid()
	if not await until(func():return other.active_terminal().get_shell_pid()>0,"Sibling actual PID ready"):return
	other_pid=other.active_terminal().get_shell_pid()
	host.workspace_view.overview=true
	host.workspace_view.navigation_zoom=.75
	host.workspace_view.navigation_center=Vector2(800,600)
	host.workspace_view._apply_navigation()
	var bar: Node=host.workspace_view.tab_bar
	host.get_window().grab_focus()
	await hold(.2)
	bar.navigation.all_tabs.pressed.emit()
	await process_frame
	check(bar.navigation.menu.visible,"All chooser opens actual list")
	bar.navigation.menu.hide()
	check(await app.move_workspace(other,host,other_id),"Move sibling tab into original window")
	bar.navigation.all_tabs.pressed.emit()
	await process_frame
	for index in bar.navigation.menu.list.item_count:
		if int(bar.navigation.menu.list.get_item_metadata(index))==active:
			bar.navigation.menu.list.item_activated.emit(index)
			break
	if not await until(func():return app.hosts.size()==1 and host.sessions.has(other_id),"Individual transfer rehomes sibling exactly once"):return
	await camera_at_rest()
	check(host.pane_focus==focused and host.active_terminal().get_shell_pid()==pid and host.workspace_layout.active==active,"All chooser restores original focused tab and shell")
	check(host.sessions[other_id].term.get_shell_pid()==other_pid,"Transferred tab retains real shell PID")
	check(absf(host.workspace_view.navigation_zoom-.75)<.001 and host.workspace_view.navigation_center.distance_to(Vector2(800,600))<.01,"All chooser restores original camera")
	var pids: Dictionary={active:pid,other_id:other_pid}
	for index in 12:
		var count: int=host.get_tabs().size()
		host.create_session()
		if not await until(func():return host.get_tabs().size()>count and host.active_terminal()!=null and host.active_terminal().get_shell_pid()>0,"Overflow tab %d has real shell" % index):return
		var id: int=host.active_session_id
		pids[id]=host.active_terminal().get_shell_pid()
	await owner_at_rest()
	root.content_scale_size=Vector2i(480,700)
	root.size=Vector2i(480,700)
	await hold(.8)
	var scroll: HScrollBar=bar.tabs.get_h_scroll_bar()
	check(scroll.max_value>scroll.page,"Real tab strip overflows")
	var end: float=scroll.value
	bar.navigation.previous_tabs.pressed.emit()
	await hold(.1)
	var back: float=scroll.value
	bar.navigation.next_tabs.pressed.emit()
	await hold(.1)
	check(back<end and scroll.value>back,"Previous and Next buttons move real overflow strip")
	bar.navigation.all_tabs.pressed.emit()
	await hold(.1)
	overlay.hide()
	picture(host,"tab-overflow-list")
	var found: int=-1
	for i in bar.navigation.menu.list.item_count:
		if int(bar.navigation.menu.list.get_item_metadata(i))==active:
			found=i
			break
	if not check(found>=0,"Original stable tab ID remains in All list"):return
	bar.navigation.menu.list.item_activated.emit(found)
	await camera_at_rest()
	check(host.workspace_layout.active==active and host.active_terminal().get_shell_pid()==pid,"All list selects original tab and PID")
	for id in pids:check(host.sessions.has(id) and host.sessions[id].term.get_shell_pid()==pids[id],"Overflow preserves shell %d" % id)
	picture(host,"tab-overflow-selected")
	FileAccess.open(directory.path_join("trace.json"),FileAccess.WRITE).store_string(JSON.stringify({"pids":pids,"scroll_end":end,"scroll_back":back}))
	release.call()
