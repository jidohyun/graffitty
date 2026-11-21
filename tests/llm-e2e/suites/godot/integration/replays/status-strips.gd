extends "terminal-tools.gd"
var status_trace: Array = []

func inspect_strips(name: String, keys: Array[String]) -> void:
	var view: Control = host.workspace_view
	var mapping: Transform2D = view._status_navigation_transform()
	var boxes: Array[Rect2] = []
	var trace := {"name":name,"panes":[]}
	for key in keys:
		if not check(view.status_strips.has(key) and view.status_strips[key].visible,"Visible status for "+key):continue
		var strip: Control = view.status_strips[key]
		var rect := mapping * Rect2(strip.position,strip.size*strip.scale)
		for pane in view.panes.values():
			check(not rect.intersects(mapping*pane.get_rect()),"Status avoids pane content: "+key)
		for other in boxes:check(not rect.intersects(other),"Status strips do not overlap")
		boxes.append(rect)
		for output in [false,true]:
			for port: Control in view.agent_links.sockets(output).values():
				if port.is_visible_in_tree():
					var anchor: Vector2 = port.get_meta("sheet_anchor")
					var offset: Vector2 = port.get_meta("anchor_offset")
					check(not rect.intersects(Rect2(mapping*anchor+offset,port.size)),"Status avoids advertised port")
		var sample: Dictionary = host.resource_monitor_for(int(key.substr(1))).snapshot()
		var status: Dictionary = view.pane_status[key]
		strip.render_now()
		check(status.cpu==("%.0f%%" % float(sample.cpu_percent)) and status.memory!="—" and status.cpu in strip.texts(),"Displayed resources match actual owner sample")
		check(str(status.label).begins_with(".") and key in str(status.label),"Strip identifies the pane by position and stable ID")
		check(strip.mouse_filter!=Control.MOUSE_FILTER_STOP and not strip.hit_keys().is_empty(),"Status strip does not capture pointer")
		trace.panes.append({"key":key,"title":status.label,"text":strip.texts(),"sample":sample,"rect":[rect.position.x,rect.position.y,rect.size.x,rect.size.y]})
	status_trace.append(trace)
	capture(name)

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var first: int = host.active_session_id
	await host.set_pane_title("%%%d" % first,"Status Alpha")
	host.create_terminal_window("","h")
	var deadline := Time.get_ticks_msec()+10000
	while host.sessions.size()<2 and Time.get_ticks_msec()<deadline:await process_frame
	var second: int = host.active_session_id
	await host.set_pane_title("%%%d" % second,"Status Beta")
	var keys: Array[String] = ["%%%d" % first,"%%%d" % second]
	check(host.sessions[first].term.get_shell_pid()!=host.sessions[second].term.get_shell_pid(),"Status panes own independent real shells")
	await app.agent_api.dispatch(first,"agent.event",{"provider":"adapter","event":"SessionStart"})
	await app.agent_api.dispatch(first,"agent.register",{"name":"Status Adapter","inputs":[{"id":"in"}],"outputs":[{"id":"out"}]})
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await camera_at_rest()
	var view: Control = host.workspace_view
	view.zoom_workspace(.45,view.size*.5)
	await hold(.5)
	deadline = Time.get_ticks_msec()+16000
	while Time.get_ticks_msec()<deadline:
		if host.resource_monitor_for(first).cpu_valid and host.resource_monitor_for(second).cpu_valid:break
		await process_frame
	check(host.resource_monitor_for(first).cpu_valid and host.resource_monitor_for(second).cpu_valid,"Real owner resource samples become available")
	overlay.hide()
	await inspect_strips("status-strips-first",keys)
	check(view.pane_status[keys[0]].agent!=null and view.pane_status[keys[1]].agent==null,"Only registered adapter pane has agent badge")
	view.pan_workspace(Vector2(80,-30),view.size*.5)
	view.zoom_workspace(1.05,view.size*.5)
	await hold(.3)
	await inspect_strips("status-strips-panned",keys)
	view.show_main()
	await hold(.3)
	check(not view.status_strips[keys[0]].visible and not view.status_strips[keys[1]].visible,"Fitted main view hides overview strips")
	view.zoom_workspace(.45,view.size*.5)
	view.pan_workspace(Vector2(10000,0),view.size*.5)
	await hold(.3)
	check(not view.status_strips[keys[0]].visible and not view.status_strips[keys[1]].visible,"Offscreen panes leave no orphan strips")
	FileAccess.open(directory.path_join("status-trace.json"),FileAccess.WRITE).store_string(JSON.stringify(status_trace,"  "))
	release.call()
