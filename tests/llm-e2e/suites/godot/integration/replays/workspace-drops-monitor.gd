extends "remote-window-return.gd"
var monitor_only := false

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	var original: int=host.active_session_id
	var pid: int=terminal.get_shell_pid()
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	var monitor: Node=host.resource_monitor_for(original)
	monitor.set_interval(.1)
	host.pane_status_visible=true
	host.workspace_view.refresh()
	if not await until(func():return monitor.snapshot().get("cpu_valid",false) and monitor.snapshot().get("memory_current",0)>0,"Owner supplies real CPU/memory sample"):return
	var view: Node=host.workspace_view
	view._update_monitor()
	await hold(.2)
	var dialog := preload("res://scenes/PaneStatusDialog.gd").find(host)
	var readout: String = "\n".join(dialog.texts())
	var processes := func() -> String: return dialog.view.get_tooltip(dialog.view.hit_rect("metric-processes").get_center())
	check(("PID %d" % pid) in processes.call() and ("%.1f MiB" % (float(monitor.snapshot().memory_peak_observed)/1048576.0)) in readout,"Monitor names actual shell PID and measured peak")
	var old_position: Vector2i = dialog.position
	dialog.position += Vector2i(40, 30)
	check(dialog.position != old_position, "Monitor window moves independently of workspace")
	# Native title/touch dragging is covered by the shared docking fixtures.
	var sample_time: int = monitor._received_msec
	await until(func():return monitor._received_msec>sample_time,"Another actual owner sample arrives",8.0)
	await hold(.2)
	dialog.texts()
	check(("PID %d" % pid) in processes.call(),"The mod readout follows owner sampling without polling")
	overlay.hide()
	picture(host,"monitor-dragged")
	var zoom: float=view.navigation_zoom
	var magnify:=InputEventMagnifyGesture.new()
	magnify.position=Vector2(dialog.size) * .5
	magnify.factor=1.2
	dialog.push_input(magnify,true)
	await process_frame
	check(view.navigation_zoom==zoom,"Monitor viewport does not forward zoom gestures to the workspace")
	magnify.position=Vector2(100,700)
	root.push_input(magnify,true)
	await process_frame
	check(view.navigation_zoom!=zoom,"Gesture in the main window still reaches workspace")
	if monitor_only:
		release.call()
		return
	host.pane_status_visible=false
	view.refresh()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	if not await command("\u001b[?2004h\u001b[5;1HDROP_READY\u001b[6;1H",Vector2i(0,5)):return
	var paths: PackedStringArray=[directory.path_join("a'b 한글.txt"),directory.path_join("$(Write-Output EXECUTED).txt")]
	for path in paths:FileAccess.open(path,FileAccess.WRITE).store_string("fixture")
	var modal:=AcceptDialog.new()
	modal.dialog_text="File drops must not type behind this dialog."
	host.add_child(modal)
	modal.popup_centered()
	await process_frame
	root.files_dropped.emit(paths)
	modal.hide()
	modal.queue_free()
	await process_frame
	root.gui_release_focus()
	root.files_dropped.emit(paths)
	await hold(.2)
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if not await wait_file(directory.path_join("receipt.json")):return
	var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
	var quoted:=PackedStringArray()
	for path in paths:quoted.append("'"+path.replace("'","''")+"'")
	var expected: String="\u001b[200~"+" ".join(quoted)+"\u001b[201~"
	check(receipt.text==expected,"Native file-drop signal sends exact PowerShell quotes, Unicode and bracketed paste without a trailing separator; modal drop sends nothing: "+receipt.utf8_hex)
	check(terminal.get_shell_pid()==pid,"File drops keep original live shell")
	FileAccess.open(directory.path_join("monitor-sample.json"),FileAccess.WRITE).store_string(JSON.stringify(monitor.snapshot()))
	release.call()
