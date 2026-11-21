extends SceneTree
## Run through test_terminal_owner_api.py's isolated raw PTY fixture.
var failures := 0
var activity: Array[int] = []

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1000, 700)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = PackedStringArray(["--no-plugin", "--workspace=main", "--attach-session"])
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null:
		check(false, "Production workspace starts")
		quit(1)
		return
	var host: Node = wrapper.host
	while not host.sessions.has(host.active_session_id) and Time.get_ticks_msec() < deadline: await process_frame
	var id: int = host.active_session_id
	var terminal: Node = host.sessions[id].term
	while "@@READY@@" not in str(terminal.get_text(false).get("text", "")) and Time.get_ticks_msec() < deadline: await process_frame
	terminal.keystroke.connect(func(_cell, unicode): activity.append(unicode))
	var api: Node = host.application.agent_api
	var captured: Dictionary = await api.dispatch(id, "terminal.get_text", {})
	check("@@READY@@" in str(captured.get("result", {}).get("text", "")), "Godot API captures authoritative owner text")
	# The old viewport injection route would reject or drop this input.
	host.sessions[id].vp.gui_disable_input = true
	var typed: Dictionary = await api.dispatch(id, "terminal.type", {"text":"한🙂", "interval_ms":0})
	check(typed.get("result", {}).get("keys_sent", 0) == 2, "Typing completes through the owner with viewport input disabled")
	var pressed: Dictionary = await api.dispatch(id, "terminal.press", {"key":"Alt+b", "interval_ms":0})
	check(pressed.get("result", {}).get("keys_sent", 0) == 1, "Alt shortcut is encoded by the owner")
	deadline = Time.get_ticks_msec() + 3000
	while activity.size() < 3 and Time.get_ticks_msec() < deadline: await process_frame
	check(activity == ["한".unicode_at(0), "🙂".unicode_at(0), 98], "Typing effects observe each input exactly once")
	var quiet: Dictionary = await api.dispatch(id, "terminal.press", {"key":"Ctrl+h", "effects":false, "interval_ms":0})
	check(quiet.get("result", {}).get("keys_sent", 0) == 1, "Quiet key is delivered through the owner")
	await api.dispatch(id, "terminal.press", {"key":"c", "effects":true, "interval_ms":0})
	deadline = Time.get_ticks_msec() + 3000
	while activity.size() < 4 and Time.get_ticks_msec() < deadline: await process_frame
	check(activity == ["한".unicode_at(0), "🙂".unicode_at(0), 98, 99], "Quiet input skips effects while the following ordinary key retains them")
	var pids: Dictionary = await api.dispatch(id, "terminal.pid", {})
	check(pids.get("result", {}).get("terminals", []).size() == 1, "PID queries use the server API")
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	for _i in 5: await process_frame
	quit(0 if failures == 0 else 1)
