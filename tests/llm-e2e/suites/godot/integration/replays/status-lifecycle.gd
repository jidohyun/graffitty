extends "terminal-tools.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var original: int = host.active_session_id
	var key := "%%%d" % original
	await host.set_pane_title(key,"Status lifecycle")
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await camera_at_rest()
	var view: Control = host.workspace_view
	view.zoom_workspace(.45,view.size*.5)
	await hold(.5)
	if not check(view.status_strips.has(key) and view.status_strips[key].visible,"Initial overview strip is visible"):return
	var strip: Control = view.status_strips[key]
	var at: Vector2 = view.window_point(strip.position+strip.size*strip.scale*.5)
	await click(at)
	check(host.active_session_id==original,"Click on noninteractive strip keeps focused shell")
	host.world.create_terminal_tab()
	var deadline := Time.get_ticks_msec()+10000
	while host.active_session_id==original and Time.get_ticks_msec()<deadline:await process_frame
	await camera_at_rest()
	check(not is_instance_valid(strip) or not strip.is_visible_in_tree(),"Switching destination removes outgoing status strip")
	host.focus_pane(key)
	await camera_at_rest()
	view.show_main()
	view.zoom_workspace(.45,view.size*.5)
	await hold(.5)
	strip=view.status_strips[key]
	check(strip.visible,"Returning restores original overview strip")
	var monitor: Node = host.resource_monitor_for(original)
	deadline=Time.get_ticks_msec()+16000
	while not monitor.cpu_valid and Time.get_ticks_msec()<deadline:await process_frame
	check(monitor.cpu_valid,"Lifecycle fixture has an actual live resource sample")
	overlay.hide()
	capture("status-lifecycle-live")
	var connection: Node = host.session_backend.connection
	if "selected" in connection:connection=connection.selected
	connection.set_process(false)
	deadline=Time.get_ticks_msec()+20000
	while view.pane_status[key].cpu!="—" and Time.get_ticks_msec()<deadline:await process_frame
	var sample: Dictionary = monitor.snapshot()
	strip.render_now()
	check(sample.status=="stale" and view.pane_status[key].cpu=="—" and view.pane_status[key].memory=="—" and "—" in strip.texts() and strip.visible,"Expired real sample shows visible unavailable CPU and RAM")
	FileAccess.open(directory.path_join("stale-sample.json"),FileAccess.WRITE).store_string(JSON.stringify(sample,"  "))
	capture("status-lifecycle-stale")
	connection.set_process(true)
	await hold(.5)
	connection.disconnect_remote()
	await hold(.2)
	check(monitor.snapshot().status=="disconnected" and view.pane_status[key].cpu=="—" and strip.visible,"Actual disconnect keeps visible unavailable status")
	capture("status-lifecycle-disconnected")
	release.call()
