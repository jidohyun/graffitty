extends "remote-window-return.gd"
func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	root.content_scale_size=Vector2i(480,700)
	root.size=Vector2i(480,700)
	var first: int=host.active_session_id
	var pids: Dictionary={first:host.active_terminal().get_shell_pid()}
	for i in 10:
		var count: int=host.get_tabs().size()
		host.create_session()
		if not await until(func():return host.get_tabs().size()>count and host.active_terminal()!=null and host.active_terminal().get_shell_pid()>0,"Overflow fixture shell %d" % i):return
		pids[host.active_session_id]=host.active_terminal().get_shell_pid()
	await owner_at_rest()
	await hold(.8)
	var bar: Node=host.workspace_view.tab_bar
	var scroll: HScrollBar=bar.tabs.get_h_scroll_bar()
	if not check(scroll.max_value>scroll.page,"Compact tabs overflow real narrow native window"):return
	var end: float=scroll.value
	bar.navigation.previous_tabs.pressed.emit()
	await hold(.1)
	var back: float=scroll.value
	bar.navigation.next_tabs.pressed.emit()
	await hold(.1)
	check(back<end and scroll.value>back,"Actual Previous and Next controls scroll tab strip")
	bar.navigation.all_tabs.pressed.emit()
	await hold(.2)
	overlay.hide()
	picture(host,"tab-overflow-list")
	var found: int=-1
	for i in bar.navigation.menu.list.item_count:
		if int(bar.navigation.menu.list.get_item_metadata(i))==first:found=i;break
	if not check(found>=0,"Original tab stable ID in overflow list"):return
	bar.navigation.menu.list.item_activated.emit(found)
	await camera_at_rest()
	check(host.active_session_id==first,"All list selects original stable tab")
	for id in pids:check(host.sessions[id].term.get_shell_pid()==pids[id],"Shell %d survives overflow navigation" % id)
	picture(host,"tab-overflow-selected")
	release.call()
