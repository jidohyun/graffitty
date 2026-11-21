extends "remote-window-return.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	root.gui_embed_subwindows=false
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	var first: int=host.active_session_id
	var first_pid: int=host.active_terminal().get_shell_pid()
	await host.create_native_window()
	var other: Node
	for candidate in app.hosts:
		if candidate!=host:other=candidate
	if not check(other!=null,"Native sibling opens"):return
	var other_release: Callable=other.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await until(func():return other.active_terminal()!=null and other.active_terminal().get_shell_pid()>0,"Sibling live PTY ready")
	var second: int=other.active_session_id
	var second_pid: int=other.active_terminal().get_shell_pid()
	await write_marker(host,"FIRST_WINDOW_RED",41)
	await write_marker(other,"SECOND_WINDOW_BLUE",44)
	var saved_center: Vector2=other.workspace_view.navigation_center
	var saved_zoom: float=other.workspace_view.navigation_zoom
	var saved_geometry: Dictionary=other.workspace_view.pane_rects.duplicate(true)
	var saved_font: int=other.active_terminal().font_size
	host.workspace_view.zoom_workspace(.7,Vector2(500,400))
	host.workspace_view.pan_workspace(Vector2(20,10),Vector2(500,400))
	host.workspace_view.toggle_fit_pane(host.pane_focus)
	await camera_at_rest()
	host.workspace_view.toggle_fit_pane(host.pane_focus)
	await camera_at_rest()
	check(other.workspace_view.navigation_center==saved_center and other.workspace_view.navigation_zoom==saved_zoom and other.workspace_view.pane_rects==saved_geometry and other.active_terminal().font_size==saved_font,"Local pan, zoom and fit preserve sibling camera geometry and font")
	check(not "FIRST_WINDOW_RED" in str(other.active_terminal().get_text(false).text),"Local input stays inside its window")
	host.create_session()
	if not await until(func():return host.get_tabs().size()==2 and host.active_terminal().get_shell_pid()>0,"Transfer tab owns live PTY"):return
	var carried: int=host.active_session_id
	var carried_pid: int=host.active_terminal().get_shell_pid()
	await write_marker(host,"CARRIED_OUTPUT",45)
	check(await app.move_workspace(host,other,carried),"Actual window transfer accepts tab")
	await hold(.5)
	check(other.sessions.has(carried) and other.sessions[carried].term.get_shell_pid()==carried_pid and "CARRIED_OUTPUT" in str(other.sessions[carried].term.get_text(false).text),"Moving preserves tab identity, PID and actual output")
	var detached: Node=await app.detach_workspace(other,carried)
	if not check(detached!=null and detached!=other,"Transferred tab detaches into independent native window"):return
	await until(func():return detached.get_parent().connection.connected,"Detached window owner connects")
	await hold(2.8)
	check(detached.sessions[carried].term.get_shell_pid()==carried_pid,"Detach retains carried PID")
	overlay.hide()
	picture(detached,"detached-local-window")
	var old_windows: Array[WeakRef]=[weakref(other.get_window()),weakref(detached.get_window())]
	host.select_workspace(first)
	check(await app.move_workspace(other,host,second),"Move sibling tab into original window")
	check(await app.move_workspace(detached,host,carried),"Move detached tab into original window")
	host.select_workspace(first)
	await hold(.4)
	check(app.hosts.size()==1 and host.get_tabs().size()==3,"Consolidation rehomes every surviving tab exactly once")
	for reference in old_windows:check(reference.get_ref()==null or not reference.get_ref().visible,"Emptied source native window retires without stale pixels")
	check(host.sessions[first].term.get_shell_pid()==first_pid and host.sessions[second].term.get_shell_pid()==second_pid and host.sessions[carried].term.get_shell_pid()==carried_pid,"Consolidation keeps all three original shells")
	await write_marker(host,"CONSOLIDATED_LOCAL_DONE",41)
	await camera_at_rest()
	await hold(2.8)
	picture(host,"consolidated-local-windows")
	release.call()
