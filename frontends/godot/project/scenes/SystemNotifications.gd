extends Node
## Application-owned notification lifetimes and OSC 99 replies, scoped by emitter.
const Protocol := preload("res://scenes/NotificationProtocol.gd")
var application: Node
var pending: Array[Dictionary] = []
var protocols: Dictionary = {}
var serial := 0
var focus_bindings: Dictionary = {}

func native_supported() -> bool:
	# The helper is a desktop executable; Android/iOS have no native adapter.
	return OS.get_name() in ["macOS", "Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]

func bind_notification(id: int, notification_id: String, event: Dictionary, mode: String) -> Dictionary:
	var targets: Array[String] = []
	var candidates: Array = []
	if mode == "original_sender": candidates.append(event.get("origin", {}).get("source", ""))
	if mode != "this_pane": candidates.append(event.get("source", ""))
	candidates.append("%%%d" % id)
	for candidate in candidates:
		var key := str(candidate)
		if RegEx.create_from_string("^%[0-9]+$").search(key) != null and key not in targets: targets.append(key)
	if focus_bindings.size() >= 256: focus_bindings.erase(focus_bindings.keys()[0])
	focus_bindings["%d/%s" % [id, notification_id]] = {"targets": targets, "expires": Time.get_ticks_msec() + 30000}
	return {"focus_targets": targets}

func _focus_notification(job: Dictionary) -> void:
	for key in job.request.get("focus_targets", ["%%%d" % job.id]):
		var result: Dictionary = application.agent_api.inspect_terminal(int(str(key).substr(1)))
		if not result.has("error"): return

func _owner(terminal: Control) -> Dictionary:
	for host in application.hosts:
		for id in host.sessions:
			if host.sessions[id].term == terminal: return {"id": id, "host": host}
	return {}

func _protocol(id: int) -> RefCounted:
	if not protocols.has(id): protocols[id] = Protocol.new()
	return protocols[id]

func notify(terminal: Control, title: String, body: String) -> void:
	var owner := _owner(terminal)
	if owner.is_empty(): return
	# Use an independent assembler so legacy messages cannot finish an OSC 99 draft.
	var protocol := Protocol.new()
	var draft: Dictionary = {}
	for part in [["title", title if not title.is_empty() else "Graffitty"], ["body", body]]:
		var bytes: PackedByteArray = str(part[1]).left(16384).to_utf8_buffer()
		for offset in range(0, bytes.size(), 1536):
			protocol.receive("p=%s:e=1:d=0;%s" % [part[0], Marshalls.raw_to_base64(bytes.slice(offset, offset + 1536))])
	draft = protocol.receive("d=1;")
	if not draft.is_empty(): _show(owner.id, terminal, draft)

func command(terminal: Control, packet: String) -> void:
	var owner := _owner(terminal)
	if owner.is_empty(): return
	var draft: Dictionary = _protocol(owner.id).receive(packet)
	if draft.is_empty(): return
	match draft.op:
		"?":
			if not native_supported():
				terminal.send_text(Protocol.reply(draft.id, "?", ""))
				return
			var capabilities := "a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,icon,buttons,alive,close,?:s=system,silent,error,warn,warning,info,question:w=1"
			if OS.get_name() != "macOS": capabilities += ":u=0,1,2"
			terminal.send_text(Protocol.reply(draft.id, "?", capabilities))
		"alive":
			var ids: PackedStringArray = []
			for job in pending:
				if job.id == owner.id and not job.request.id.is_empty() and not job.get("closing", false): ids.append(job.request.id)
			terminal.send_text(Protocol.reply(draft.id, "alive", ",".join(ids)))
		"close":
			if draft.id.is_empty(): return
			for job in pending:
				if job.id == owner.id and job.request.id == draft.id:
					job.erase("replacement")
					_close(job)
		"show":
			var host: Node = owner.host
			var focused: bool = host.get_window().has_focus() and host.pane_focus == "%%%d" % owner.id
			var visible: bool = host.get_window().has_focus() and host.get_window().mode != Window.MODE_MINIMIZED and host.workspace_layout.containing("%%%d" % owner.id) == host.workspace_layout.active
			if (draft.occasion == "unfocused" and focused) or (draft.occasion == "invisible" and visible): return
			_show(owner.id, terminal, draft)

func _close(job: Dictionary) -> void:
	if job.get("closing", false): return
	job.closing = true


func activate(native_id: String, button := 0) -> bool:
	for job in pending:
		if job.native_id != native_id or job.get("closing", false): continue
		var terminal: Node = job.terminal.get_ref()
		if terminal == null or _owner(terminal).is_empty(): return false
		if job.expires > 0 and Time.get_ticks_msec() >= job.expires: return false
		if button < 0 or button > job.request.buttons.size(): return false
		job.activation = button
		_close(job)
		return true
	return false


func dismiss(native_id: String) -> bool:
	for job in pending:
		if job.native_id == native_id and not job.get("closing", false):
			_close(job)
			return true
	return false


func _show(id: int, terminal: Control, request: Dictionary) -> void:
	var binding_key := "%d/%s" % [id, request.id]
	if focus_bindings.has(binding_key):
		request["focus_targets"] = focus_bindings[binding_key].targets
		focus_bindings.erase(binding_key)
	if not native_supported():
		if request.get("close_report", false): terminal.send_text(Protocol.reply(request.id, "close"))
		return
	if not request.id.is_empty():
		for job in pending:
			if job.id == id and job.request.id == request.id:
				job["replacement"] = request
				_close(job)
				return
	if pending.size() >= 32:
		push_warning("System notification limit reached (32 pending)")
		return
	serial += 1
	var wire := request.duplicate()
	wire["native_id"] = "graffitty-%d-%d" % [OS.get_process_id(), serial]
	var icon_path := ""
	var bytes: PackedByteArray = preload("res://scenes/NotificationIcons.gd").resolve(request.icon_names, request.app_name, request.icon)
	if not bytes.is_empty():
		var suffix := "png" if bytes.slice(0, 8) == PackedByteArray([137,80,78,71,13,10,26,10]) else ("jpg" if bytes.slice(0, 3) == PackedByteArray([255,216,255]) else ("gif" if bytes.slice(0, 3).get_string_from_ascii() == "GIF" else ""))
		if not suffix.is_empty():
			icon_path = application.agent_api.runtime_directory.path_join(wire.native_id + "." + suffix)
			var file := FileAccess.open(icon_path, FileAccess.WRITE)
			if file != null: file.store_buffer(bytes)
	wire.erase("icon")
	wire["icon_path"] = icon_path
	var process := _spawn_helper()
	if process.is_empty():
		if not icon_path.is_empty(): DirAccess.remove_absolute(icon_path)
		push_warning("Could not start the native notification helper")
		return
	var thread := Thread.new()
	var ready := Semaphore.new()
	thread.start(_exchange.bind(process.stdio, JSON.stringify(wire), ready))
	pending.append({"id": id, "native_id":wire.native_id, "expires":Time.get_ticks_msec()+int(request.timeout) if int(request.timeout)>0 else 0,
		"terminal": weakref(terminal), "request": request, "icon_path": icon_path, "process": process, "thread": thread, "ready": ready, "written": false})

func _spawn_helper() -> Dictionary:
	var binary := preload("res://graffitty/executables.gd").cli()
	return OS.execute_with_pipe(binary, ["--desktop-notification"])

static func _exchange(pipe: FileAccess, request: String, ready: Semaphore) -> Dictionary:
	pipe.store_line(request)
	pipe.flush()
	ready.post()
	var line := pipe.get_line()
	# Closing the app terminates an outstanding helper and produces ordinary
	# EOF. Do not turn that empty response into an engine JSON parsing error.
	var parser := JSON.new()
	if line.is_empty() or parser.parse(line) != OK or not parser.data is Dictionary:
		return {"error": "Native notification helper exited without a valid response"}
	return parser.data

func _process(_dt: float) -> void:
	for key in focus_bindings.keys():
		if focus_bindings[key].expires < Time.get_ticks_msec(): focus_bindings.erase(key)
	for job in pending.duplicate():
		if not job.written and job.ready.try_wait(): job.written = true
		if job.get("closing", false) and job.written and not job.get("close_sent", false) and job.thread.is_alive():
			job.process.stdio.store_line('{"close":true}')
			job.process.stdio.flush()
			job.close_sent = true
		if job.thread.is_alive(): continue
		var response: Dictionary = job.thread.wait_to_finish()
		if job.has("activation"): response = {"clicked":true,"button":job.activation}
		pending.erase(job)
		if not job.icon_path.is_empty(): DirAccess.remove_absolute(job.icon_path)
		var terminal: Control = job.terminal.get_ref()
		if job.has("replacement"):
			if terminal != null: _show(job.id, terminal, job.replacement)
			continue
		if response.has("error"): push_warning("System notification: " + str(response.error))
		var request: Dictionary = job.request
		if terminal != null:
			if response.get("clicked", false) and (not job.get("closing", false) or job.has("activation")):
				if request.focus: _focus_notification(job)
				if request.report:
					var button: int = response.get("button", 0)
					terminal.send_text(Protocol.reply(request.id, "", str(button) if button > 0 else ""))
			if request.close_report: terminal.send_text(Protocol.reply(request.id, "close"))
	for id in protocols.keys():
		if application.host_for_workspace(id) == null:
			protocols.erase(id)
			for job in pending:
				if job.id == id: _close(job)

func _exit_tree() -> void:
	for job in pending:
		if OS.is_process_running(job.process.pid): OS.kill(job.process.pid)
		job.thread.wait_to_finish()
		if not job.icon_path.is_empty(): DirAccess.remove_absolute(job.icon_path)
	pending.clear()
