extends "../../../../replay/replay.gd"

# Only the OS banner is substituted. Actual shell bytes, terminal OSC parsing,
# pane ownership, asynchronous pipe response, and click navigation are exercised.
class Desktop extends "res://scenes/SystemNotifications.gd":
	var clicked := true
	var request_path: String
	func _spawn_helper() -> Dictionary:
		return OS.execute_with_pipe("python" if OS.get_name() == "Windows" else "python3", ["-c", "import json,sys,os,queue,threading; request=json.loads(sys.stdin.readline()); open(sys.argv[1],'w',encoding='utf-8').write(json.dumps(request)); q=queue.Queue(); threading.Thread(target=lambda:q.put(os.read(0,1024)),daemon=True).start()\ntry: q.get(timeout=.7); closed=True\nexcept queue.Empty: closed=False\nprint(json.dumps({'clicked':not closed and sys.argv[2]=='yes','button':2}),flush=True)", request_path, "yes" if clicked else "no"])

func emit_osc(id: int, message: String) -> void:
	var python := "python" if OS.get_name() == "Windows" else "python3"
	host.sessions[id].term.send_text("%s -c \"import os,base64;os.write(1,base64.b64decode('%s'))\"\r" % [python, Marshalls.utf8_to_base64(message)])

func add_pane(beside: int) -> int:
	var existing: Array = host.sessions.keys()
	host.create_terminal_window("%%%d" % beside)
	var deadline := Time.get_ticks_msec() + 10000
	while host.sessions.size() == existing.size() and Time.get_ticks_msec() < deadline:
		await process_frame
	for id in host.sessions:
		if id not in existing: return id
	check(false, "Owner creates notification fixture pane")
	return -1

func wait_notification(desktop: Node) -> void:
	var until := Time.get_ticks_msec() + 5000
	while not FileAccess.file_exists(desktop.request_path) and Time.get_ticks_msec() < until:
		await hold(0.05)
	check(FileAccess.file_exists(desktop.request_path), "Terminal OSC reaches the native notification helper")
	while not desktop.pending.is_empty() and Time.get_ticks_msec() < until:
		await hold(0.05)
	await camera_at_rest()

func play() -> void:
	await labelled_tabs(["SOURCE"])
	await camera_at_rest()
	var source: int = host.active_session_id
	var notifier := await add_pane(source)
	var relay := await add_pane(notifier)
	if notifier < 0 or relay < 0: return
	var application: Node = host.application
	var old: Node = application.system_notifications
	var desktop := Desktop.new()
	desktop.application = application
	desktop.request_path = OS.get_environment("XDG_STATE_HOME").path_join("notification-%d.json" % OS.get_process_id())
	application.add_child(desktop)
	application.system_notifications = desktop
	old.queue_free()
	if FileAccess.file_exists(desktop.request_path): DirAccess.remove_absolute(desktop.request_path)
	host.focus_pane("%%%d" % notifier)
	await camera_at_rest()
	await say("OSC 9 from a background terminal opens and fits that terminal")
	emit_osc(source, "\u001b]9;OSC9 background test\u0007")
	await wait_notification(desktop)
	check(host.active_session_id == source, "Click selects the pane that emitted OSC 9")
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(desktop.request_path))
	check("OSC9 background test" in str(request), "Native helper receives the terminal's notification text")
	var view: Control = host.workspace_view
	var target: Dictionary = view._inspection_target("%%%d" % source)
	check(view.navigation_center.distance_to(target.center) < 1 and absf(view.navigation_zoom - target.zoom) < 0.01, "Click uses Cmd+Enter fit framing")
	await application.agent_api.inspect_terminal(source)
	await camera_at_rest()
	check(view.navigation_center.distance_to(target.center) < 1, "Repeated clicks stay fitted")
	DirAccess.remove_absolute(desktop.request_path)
	desktop.clicked = false
	emit_osc(notifier, "\u001b]9;dismiss me\u0007")
	await wait_notification(desktop)
	check(host.active_session_id == source, "Dismissing a notification preserves focus")
	DirAccess.remove_absolute(desktop.request_path)
	desktop.clicked = true
	await say("The graph notification node emits OSC 99 and logs its sends")
	var config_path := OS.get_environment("XDG_STATE_HOME").path_join("notification-config-%d.json" % OS.get_process_id())
	FileAccess.open(config_path, FileAccess.WRITE).store_string("{}")
	var cli := "& $env:GRAFFITTY_BIN" if OS.get_name() == "Windows" else '"$GRAFFITTY_BIN"'
	host.sessions[notifier].term.send_text("%s node system-notification --edit --config '%s'\r" % [cli, config_path])
	var until := Time.get_ticks_msec() + 10000
	while application.agent_api.graph.nodes.get("%%%d" % notifier, {}).get("manifest", {}).get("name", "") != "System Notification" and Time.get_ticks_msec() < until:
		await hold(0.1)
	await application.agent_api.dispatch(source, "agent.event", {"kind":"custom", "event":"SessionStart", "session_id":"notification-replay-source"})
	await application.agent_api.dispatch(source, "agent.register", {"name":"Source", "inputs":[], "outputs":[{"id":"send"}]})
	await application.agent_api.dispatch(relay, "agent.event", {"kind":"custom", "event":"SessionStart", "session_id":"notification-replay-relay"})
	await application.agent_api.dispatch(relay, "agent.register", {"name":"Relay", "inputs":[{"id":"in"}], "outputs":[{"id":"out"}]})
	await application.agent_api.dispatch(source, "graph.connect", {"from":"%%%d" % source,"from_port":"send","to":"%%%d" % relay,"to_port":"in"})
	var linked: Dictionary = await application.agent_api.dispatch(relay, "graph.connect", {"from":"%%%d" % relay,"from_port":"out","to":"%%%d" % notifier,"to_port":"notify"})
	if not check(linked.has("result"), "System notification node registers its Notify input"):
		host.focus_pane("%%%d" % notifier)
		await hold(.3)
		print(linked)
		print(host.sessions[notifier].term.get_text(false))
		return
	await application.agent_api.dispatch(source, "graph.emit", {"output":"send", "payload":{"text":"Graph node OSC99 test"}})
	var inbox: Dictionary = await application.agent_api.dispatch(relay, "graph.take", {})
	var forwarded: Dictionary = await application.agent_api.dispatch(relay, "graph.forward", {"output":"out", "event_id": inbox.result.events[0].event_id})
	if not check(forwarded.has("result"), "Relay forwards the original event"):
		print(forwarded)
		return
	host.focus_pane("%%%d" % notifier)
	await hold(0.4)
	check(not FileAccess.file_exists(desktop.request_path), "Start-paused form leaves queued notifications unsent")
	host.sessions[notifier].term.send_text("\u0013")
	await hold(0.2)
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	check(saved.get("urgency") == "normal" and saved.get("focus") == "yes", "Ctrl+S saves the form defaults")
	await keys("ctrl+enter")
	await wait_notification(desktop)
	if not FileAccess.file_exists(desktop.request_path):
		print(host.sessions[notifier].term.get_text(false))
		return
	check(host.active_session_id == source, "Node notification follows original sender through the relay")
	request = JSON.parse_string(FileAccess.get_file_as_string(desktop.request_path))
	check(request.get("focus_targets") == ["%%%d" % source, "%%%d" % relay, "%%%d" % notifier], "Focus fallback retains original, previous, and receiver panes")
	check("Graph node OSC99 test" in str(request), "Graph event becomes a native notification through OSC 99")
	# The click selected the originating pane and unsubscribed this background
	# mirror. Reopen the notifier before inspecting its current Ratatui frame.
	host.focus_pane("%%%d" % notifier)
	var log_deadline := Time.get_ticks_msec() + 3000
	while not "Graph node OSC99 test" in str(host.sessions[notifier].term.get_text(false).get("text", "")) and Time.get_ticks_msec() < log_deadline:
		await process_frame
	var screen: String = str(host.sessions[notifier].term.get_text(false).get("text", ""))
	check("Graph node OSC99 test" in screen, "Ratatui log shows the sent notification body")
	# A 24-row owner grid displays the final two log lines. Scroll the real log
	# to inspect the timestamp/summary above them rather than assuming more rows.
	var notifier_term: Node = host.sessions[notifier].term
	var grid: Vector2i = notifier_term.get_grid_size()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = Vector2(10, grid.y - 2) * notifier_term.get_cell_size()
	host.sessions[notifier].vp.push_input(wheel, true)
	await hold(.3)
	screen = str(notifier_term.get_text(false).get("text", ""))
	check("Sent" in screen and Time.get_date_string_from_system() in screen, "Scrolling the Ratatui log reveals Sent and the send date")
	host.sessions[notifier].term.send_text("\u0003")
	await hold(0.3)
	DirAccess.remove_absolute(desktop.request_path)
	host.focus_pane("%%%d" % notifier)
	await say("OSC 99 reports actions and closure without stealing focus")
	var script_path := OS.get_environment("XDG_STATE_HOME").path_join("osc99-%d.py" % OS.get_process_id())
	var response_path := script_path + ".json"
	var script := r"""import os,sys,json,time,queue,threading
if os.name=='nt':
 import ctypes
 kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 kernel.GetStdHandle.restype=ctypes.c_void_p
 kernel.GetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
 kernel.SetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
 handle=kernel.GetStdHandle(-10)
 old=ctypes.c_ulong()
 assert kernel.GetConsoleMode(handle,ctypes.byref(old))
 assert kernel.SetConsoleMode(handle,(old.value & ~7) | 0x200)
else:
 import termios,tty
 old=termios.tcgetattr(0)
 tty.setraw(0)
received=queue.Queue()
def reader():
 while True:
  chunk=os.read(0,16384)
  if not chunk:return
  received.put(chunk)
threading.Thread(target=reader,daemon=True).start()
def read_available():
 try:return received.get(timeout=.1)
 except queue.Empty:return b''
try:
 def send(meta,payload=''): os.write(1, ('\x1b]99;'+meta+';'+payload+'\x1b\\').encode())
 send('i=reply-test:a=-focus,report:c=1:d=0','Action test')
 send('i=reply-test:p=buttons','First\u2028Second')
 send('i=query:p=?')
 os.write(1,b'\x1b[c')
 send('i=alive-query:p=alive')
 data=b''
 until=time.monotonic()+5
 while time.monotonic()<until:
  data+=read_available()
  if b'i=reply-test:p=close;' in data: break
 send('i=replace-test:c=1','Old title')
 time.sleep(0.15)
 send('i=replace-test:c=1','Replacement title')
 time.sleep(0.2)
 send('i=replace-test:p=close')
 until=time.monotonic()+3
 while time.monotonic()<until:
  data+=read_available()
  if b'i=replace-test:p=close;' in data: break
 with open(sys.argv[1]+'.tmp','w',encoding='utf-8') as result:
  result.write(json.dumps(data.decode()))
 os.replace(sys.argv[1]+'.tmp',sys.argv[1])
finally:
 if os.name=='nt':kernel.SetConsoleMode(handle,old.value)
 else:termios.tcsetattr(0,termios.TCSANOW,old)
"""
	FileAccess.open(script_path, FileAccess.WRITE).store_string(script)
	host.sessions[source].term.send_text("%s '%s' '%s'\r" % ["python" if OS.get_name() == "Windows" else "python3", script_path, response_path])
	until = Time.get_ticks_msec() + 7000
	while not FileAccess.file_exists(response_path) and Time.get_ticks_msec() < until: await hold(0.05)
	if check(FileAccess.file_exists(response_path), "Terminal application receives OSC 99 replies"):
		var replies: String = JSON.parse_string(FileAccess.get_file_as_string(response_path))
		check("i=query:p=?;a=focus,report" in replies, "Capability query advertises supported protocol")
		check(replies.find("i=query:p=?;") < replies.find("\u001b[?"), "Capability reply precedes device attributes for protocol detection")
		check("i=alive-query:p=alive;reply-test" in replies, "Alive query lists this terminal's notification")
		check(replies.count("i=replace-test:p=close;") == 1, "Replacement suppresses old closure; explicit close reports once")
		check("i=reply-test;2" in replies and "i=reply-test:p=close;" in replies, "Click reports the action number followed by closure")
	check(host.active_session_id == notifier, "Negative focus action preserves the active pane")
	DirAccess.remove_absolute(config_path)
	DirAccess.remove_absolute(script_path)
	DirAccess.remove_absolute(response_path)
	var result: Dictionary = await application.agent_api.inspect_terminal(999999)
	check(result.has("error") and host.active_session_id == notifier, "Closed emitter does not change focus")
	DirAccess.remove_absolute(desktop.request_path)
