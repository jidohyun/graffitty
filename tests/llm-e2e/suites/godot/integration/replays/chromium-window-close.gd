extends "font-controls.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	root.gui_embed_subwindows=false
	var first: int=host.active_session_id
	var first_pid: int=host.active_terminal().get_shell_pid()
	var browser: Node=await host.create_chromium_session("about:blank")
	if not await until(func():return browser.chromium_ready and browser.gpu_active and browser.gpu_frames>0,"Owned browser imports actual GPU frames",20):return
	var browser_id: int=browser.session_id
	var browser_pid: int=browser.pid
	var reply: Dictionary=await browser.request("cdp",{"method":"Runtime.evaluate","params":{"expression":"document.body.style='background:#245260;color:white;font:28px sans-serif';document.body.innerHTML='<h1>Retained browser ownership</h1><input id=i value=KEEP_BROWSER_164>';window.identity='PAGE_164';'ready'","returnByValue":true}})
	check(reply.get("result",{}).get("result",{}).get("value")=="ready","Real browser document initialized")
	host.create_session()
	if not await until(func():return host.get_tabs().size()==2 and host.active_terminal().get_shell_pid()>0,"Unrelated shell starts"):return
	var unrelated: int=host.active_session_id
	var unrelated_pid: int=host.active_terminal().get_shell_pid()
	var browser_tab: int=host.workspace_layout.containing("%%%d"%browser_id)
	check(host.workspace_layout.containing("%%%d"%first)==browser_tab,"Browser opens beside its owner terminal")
	# A browser moves with its owner; there is no browser-only move.
	var browser_host: Node=await app.detach_workspace(host,browser_tab)
	if not check(browser_host!=null and browser_host!=host,"Browser tab detaches into another native window"):return
	await until(func():return browser_host.get_parent().connection.connected,"Browser window authenticates in the owner workspace")
	await hold(.8)
	check(browser_host.sessions.has(first) and browser_host.chromiums.has(browser_id),"The owner terminal moves with its browser")
	var moved: Node=browser_host.chromiums[browser_id]
	check(moved.pid==browser_pid and browser_host.sessions[first].term.get_shell_pid()==first_pid,"Browser and owner shell processes survive the native-window move")
	reply=await moved.request("cdp",{"method":"Runtime.evaluate","params":{"expression":"identity+':'+i.value","returnByValue":true}})
	check(reply.get("result",{}).get("result",{}).get("value")=="PAGE_164:KEEP_BROWSER_164","Moved browser retains document and input state")
	if not await until(func():
		RenderingServer.force_draw(false)
		var pixels: Image=browser_host.get_window().get_texture().get_image()
		if pixels==null or pixels.is_empty():return false
		var matching:=0
		for y in range(120,pixels.get_height(),25):
			for x in range(20,pixels.get_width(),25):
				var color:=pixels.get_pixel(x,y)
				if absf(color.r-36.0/255)<.03 and absf(color.g-82.0/255)<.03 and absf(color.b-96.0/255)<.03:matching+=1
		return matching>150,"Detached browser canvas actually presents retained page pixels",15):return
	var focus: String=host.pane_focus
	var camera: Vector2=host.workspace_view.navigation_center
	overlay.hide()
	picture(browser_host,"browser-native-window")
	FileAccess.open(directory.path_join("process-watch.json"),FileAccess.WRITE).store_string(JSON.stringify({"owner_shell":{"pid":first_pid,"exited":true},"browser":{"pid":browser_pid,"exited":true},"survivor":{"pid":unrelated_pid,"exited":false}}))
	# Replay files live in the repository, while res:// may be an isolated build.
	var helper: String=get_script().resource_path.get_base_dir().path_join("../../../../../platform/windows/windows_process_receipt.py").simplify_path()
	OS.create_process(OS.get_environment("GRAFFITTY_INPUT_PYTHON"),PackedStringArray([helper,directory]),false)
	if not await until(func():return FileAccess.file_exists(directory.path_join("process-watch-ready")),"Original process handles retained before confirmation"):return
	var browser_ref: WeakRef=weakref(browser_host)
	browser_host.request_close_window()
	if not await until(func():return browser_host.close_dialog!=null and browser_host.close_dialog.visible,"Closing a window with a browser asks first"):return
	check(browser_host.close_dialog.get_cancel_button().has_focus(),"Close warning starts with Cancel focus")
	await hold(.2)
	RenderingServer.force_draw(false)
	browser_host.close_dialog.get_texture().get_image().save_png(directory.path_join("browser-window-close-warning.png"))
	browser_host.close_dialog.get_cancel_button().pressed.emit()
	await hold(.2)
	check(browser_host.sessions[first].term.get_shell_pid()==first_pid and browser_host.chromiums[browser_id].pid==browser_pid,"Cancel retains terminal and browser process identities")
	browser_host.request_close_window()
	await until(func():return browser_host.close_dialog!=null and browser_host.close_dialog.visible,"Close warning can be reopened")
	browser_host.close_dialog.get_ok_button().pressed.emit()
	FileAccess.open(directory.path_join("process-watch-close"),FileAccess.WRITE).close()
	await until(func():return browser_ref.get_ref()==null,"Closing the window retires its terminal and browser",15)
	if await until(func():return FileAccess.file_exists(directory.path_join("process-receipt.json")),"Process cleanup receipt arrives"):
		check(JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("process-receipt.json"))).get("status")=="PASS","Browser and owner shell exit within five seconds while the unrelated shell lives")
	check(host.sessions.has(unrelated) and host.active_terminal().get_shell_pid()==unrelated_pid and host.pane_focus==focus and host.workspace_view.navigation_center==camera,"The original window retains its shell, focus and camera")
	await write_marker(host,"SURVIVOR_AFTER_BROWSER_WINDOW_CLOSE",42)
	picture(host,"surviving-native-window")
	FileAccess.open(directory.path_join("identities.json"),FileAccess.WRITE).store_string(JSON.stringify({"owner_pid":first_pid,"browser_pid":browser_pid,"survivor_pid":unrelated_pid,"browser_tab":browser_tab},"  "))
