extends "remote-window-return.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	var original: int=host.active_session_id
	var pid: int=terminal.get_shell_pid()
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	var chromium: Node=await host.create_chromium_session("about:blank")
	if not check(chromium!=null,"Private real Chromium created"):return
	if not await until(func():return chromium.chromium_ready and chromium.gpu_active and chromium.gpu_frames>0,"Actual CEF GPU frames imported",20.0):return
	var result: Dictionary=await chromium.request("cdp",{"method":"Runtime.evaluate","params":{"expression":"document.body.style='background:#245260;color:white;font:28px sans-serif';document.body.innerHTML='<h1>Chromium resource identity</h1><input placeholder=Private>';document.title='Resource fixture';'CHROMIUM_RESOURCE_READY'","returnByValue":true}})
	check(result.get("result",{}).get("result",{}).get("value")=="CHROMIUM_RESOURCE_READY","Actual browser RPC completes document update")
	if not await until(func():
		var pixels: Image=root.get_texture().get_image()
		if pixels==null or pixels.is_empty():return false
		for y in range(pixels.get_height()/3,pixels.get_height()*2/3,20):
			for x in range(pixels.get_width()/2,pixels.get_width()-40,20):
				var sample: Color=pixels.get_pixel(x,y)
				if absf(sample.r-36.0/255)<.025 and absf(sample.g-82.0/255)<.025 and absf(sample.b-96.0/255)<.025:return true
		return false,"Presented browser pixels contain updated document",15.0):return
	var source: Node=host.resource_monitor_for(chromium.session_id)
	if not await until(func():return source.snapshot().get("status")=="running" and source.snapshot().get("memory_current",0)>0,"Browser supplies measured running resource sample",20.0):return
	host.focus_pane("%%%d" % chromium.session_id)
	host.pane_status_visible=true
	host.workspace_view.refresh()
	await hold(.3)
	var data: Dictionary=source.snapshot()
	check(int(data.root_pid)==chromium.pid and int(data.root_pid)!=pid and int(data.process_count)>0,"Browser monitor identifies actual CEF process tree instead of shell")
	var monitor_view: Control = preload("res://scenes/PaneStatusDialog.gd").find(host).view
	check(("PID %d" % chromium.pid) in monitor_view.get_tooltip(monitor_view.hit_rect("metric-processes").get_center()),"Focused browser monitor shows actual Chromium PID")
	overlay.hide()
	picture(host,"monitor-chromium-resources")
	FileAccess.open(directory.path_join("chromium-sample.json"),FileAccess.WRITE).store_string(JSON.stringify(data))
	host.pane_status_visible=false
	host.workspace_view.refresh()
	host.focus_pane("%%%d" % original)
	await camera_at_rest()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	host.focus_pane("%%%d" % chromium.session_id)
	root.files_dropped.emit(PackedStringArray([directory.path_join("BROWSER_DROP_MUST_NOT_TYPE.txt")]))
	await hold(.3)
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Chromium focus suppresses terminal file drop without raw PTY leakage")
	check(terminal.get_shell_pid()==pid,"Browser monitor and dropped paths preserve original shell")
	release.call()
