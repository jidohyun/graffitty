extends "../../tabs-and-panes/replays/remote-access.gd"
## Private profiles, committed IndexedDB and the real Sessions controls.
var http := TCPServer.new()
var clients: Array[StreamPeerTCP] = []
var evidence := ""
var url := ""

func serve() -> void:
	while http.is_connection_available(): clients.append(http.take_connection())
	for client in clients.duplicate():
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(client)
			continue
		if client.get_available_bytes() > 0:
			client.get_data(client.get_available_bytes())
			var body := "<!doctype html><body style='background:#183044;color:white;font:28px sans-serif'><h1>Private profile acceptance</h1><p id=marker>Loading</p>"
			client.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]).to_utf8_buffer())
			clients.erase(client)

func browser(profile: Variant) -> Node:
	var node: Node = await host.create_chromium_session(url, -1, true, profile)
	if not check(node != null, "Private owner creates browser"): return null
	var deadline := Time.get_ticks_msec() + 30000
	while not node.chromium_ready and Time.get_ticks_msec() < deadline: await process_frame
	if not check(node.chromium_ready, "Profile browser reaches ready state"): return null
	var loaded := false
	while not loaded and Time.get_ticks_msec() < deadline:
		var response: Dictionary = await node.request("cdp", {"method":"Runtime.evaluate", "params":{
			"expression":"location.href===%s && !!document.getElementById('marker')" % JSON.stringify(url), "returnByValue":true}})
		loaded = response.get("result", {}).get("result", {}).get("value") == true
		await process_frame
	if not check(loaded, "Private HTTP origin and document finish loading before IndexedDB access"): return null
	return node

func value(node: Node, write: String = "") -> Variant:
	# Resolve only on transaction completion, never on the individual put.
	var script := """new Promise((resolve,reject)=>{let r=indexedDB.open('acceptance',1);r.onupgradeneeded=()=>r.result.createObjectStore('data');r.onerror=()=>reject(String(r.error));r.onsuccess=()=>{let db=r.result;let v=%s;let tx=db.transaction('data',v?'readwrite':'readonly',{durability:'strict'});let result=null;let s=tx.objectStore('data');if(v){s.put(v,'marker');result=v;tx.commit()}else{s.get('marker').onsuccess=e=>result=e.target.result??null}tx.oncomplete=()=>{db.close();document.querySelector('#marker').textContent=result??'EMPTY';resolve(result)};tx.onabort=()=>reject(String(tx.error))}})""" % JSON.stringify(write)
	var result: Dictionary = await node.request("cdp", {"method":"Runtime.evaluate", "params":{"expression":script,"awaitPromise":true,"returnByValue":true}})
	check(not result.has("error") and not result.get("result", {}).has("exceptionDetails"), "IndexedDB operation completes without errors")
	if result.has("error") or result.get("result", {}).has("exceptionDetails"): print("INDEXEDDB_ERROR ", result)
	return result.get("result", {}).get("result", {}).get("value")

func close_browser(node: Node) -> void:
	var pid: int = node.pid
	var runtime: String = node.directory
	host.close_chromium_session(node.session_id)
	var deadline := Time.get_ticks_msec() + 30000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline: await process_frame
	check(not OS.is_process_running(pid), "Original Chromium process exits before profile reopens")
	while DirAccess.dir_exists_absolute(runtime) and Time.get_ticks_msec() < deadline: await process_frame
	check(not DirAccess.dir_exists_absolute(runtime), "Owner removes the closed private runtime")

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	await camera_at_rest()
	check(not app.remote_access_enabled(), "Private headless owner starts with network sharing disabled")
	var pid: int = host.sessions[host.active_session_id].term.get_shell_pid()
	check(http.listen(0,"127.0.0.1") == OK, "Private IndexedDB origin listens")
	url = "http://127.0.0.1:%d/" % http.get_local_port()
	process_frame.connect(serve)
	var marker := "PROFILE_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var node := await browser(null)
	if node == null: return
	check(node.persistent_profile, "Omitted profile uses the server default")
	var default_path: String = node.profile_directory
	check(await value(node,marker) == marker, "Strict IndexedDB write commits the exact unique marker")
	await close_browser(node)
	for i in 2:
		node = await browser("")
		if node == null: return
		check(not node.persistent_profile and node.profile_directory != default_path, "Explicit empty profile is private and temporary")
		check(await value(node) == null, "Temporary browser starts empty on creation %d" % i)
		await value(node,"TEMPORARY")
		await close_browser(node)
	node = await browser(evidence.path_join("alternate-profile"))
	if node == null: return
	check(await value(node) == null, "Explicit alternate profile starts empty")
	check(await value(node,"ALTERNATE") == "ALTERNATE", "Alternate profile commits independent data")
	await close_browser(node)
	node = await browser(null)
	if node == null: return
	check(node.profile_directory == default_path and await value(node) == marker, "Reopened default profile retains exact committed data after alternate profiles")
	host.workspace_view.toggle_fit_pane("%%%d" % node.session_id)
	await camera_at_rest()
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(evidence.path_join("persistent-profile-reopened.png"))
	FileAccess.open(evidence.path_join("profile-receipt.json"),FileAccess.WRITE).store_string(JSON.stringify({"marker":marker,"profile":default_path,"pid":pid}))
	await close_browser(node)
	process_frame.disconnect(serve)
	http.stop()
	check(host.sessions[host.active_session_id].term.get_shell_pid() == pid, "Profile operations preserve the original terminal")
	await super.play()
	if OS.get_name() == "Windows":
		var helper := ProjectSettings.globalize_path(get_script().resource_path.get_base_dir().path_join("../../windows/replays/native-menu.py"))
		OS.create_process("python",[helper,str(OS.get_process_id()),evidence])
		for button in host.window_menu.get_child(0).get_children():
			if button is MenuButton and button.get_popup() == host.popup_menus.get("Sessions"):
				await click(on(button))
				break
		check(FileAccess.file_exists(evidence.path_join("native-menu.json")), "Actual Sessions controls captured for visual review")
