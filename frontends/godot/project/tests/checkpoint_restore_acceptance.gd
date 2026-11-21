extends "res://tests/checkpoint_restore_smoke.gd"
## Private Windows round-trip evidence, orchestrated by windows_restore_e2e.py.
var independent: Node
var independent_pid := -1

func prepare_restore() -> Node:
	if OS.get_environment("RESTORE_WITH_EXISTING") != "1": return root
	var app: Node = root.get_node("TerminalApplication")
	app.checkpoints = preload("res://scenes/Checkpoints.gd").new()
	app.checkpoints.application = app
	app.checkpoints.startup_loaded = true
	app.add_child(app.checkpoints)
	var existing: Node = load("res://scenes/terminal.tscn").instantiate()
	existing.launch_args = PackedStringArray(["--cwd=" + OS.get_environment("RESTORE_EXISTING_CWD")])
	root.add_child(existing)
	var deadline := Time.get_ticks_msec() + 15000
	while existing.host == null and Time.get_ticks_msec() < deadline: await process_frame
	independent = existing.host
	independent_pid = independent.active_terminal().get_shell_pid()
	FileAccess.open(OS.get_environment("RESTORE_EVIDENCE").path_join("independent.json"), FileAccess.WRITE).store_string(JSON.stringify({"pid": independent_pid}))
	app.checkpoints.startup_loaded = false
	var window := Window.new()
	window.size = Vector2i(1000, 700)
	app.add_child(window)
	window.show()
	return window

func observe_restore(app: Node, snapshot: Dictionary) -> bool:
	if independent != null and independent.active_terminal().get_shell_pid() != independent_pid:
		return false
	for host in app.hosts:
		if host == independent: continue
		var view: Node = host.workspace_view
		if not view.overview or absf(view.navigation_zoom - 0.8) > 0.0001 or view.navigation_center.distance_to(Vector2(460, 340)) > 0.01:
			print("RESTORE VIEW MISMATCH: ", view.overview, " ", view.navigation_zoom, " ", view.navigation_center)
			return false
	var directory := OS.get_environment("RESTORE_EVIDENCE")
	FileAccess.open(directory.path_join("captured.json"), FileAccess.WRITE).store_string(JSON.stringify(snapshot))
	await create_timer(2.0).timeout
	var geometry := []
	for host in app.hosts:
		var view: Node = host.workspace_view
		geometry.append({"window": str(host.get_window().size), "view": str(view.size), "visible": str(view.viewport_content_rect()), "content": str(view.content_rect()), "fit": str(view.window_fit_rect())})
	FileAccess.open(directory.path_join("geometry.json"), FileAccess.WRITE).store_string(JSON.stringify(geometry))
	for host in app.hosts:
		for definition in host.get_terminal_tabs():
			var id := int(definition.id)
			var term: Node = host.session_for(id, host.world).term
			var command := "& '%s' '%s' '%s'\r" % [
				OS.get_environment("RESTORE_PYTHON").replace("'", "''"),
				OS.get_environment("RESTORE_RECEIPT_SCRIPT").replace("'", "''"),
				directory.path_join("pane-%d.json" % id).replace("'", "''")]
			term.send_text(command)
	var deadline := Time.get_ticks_msec() + 15000
	var complete := false
	while not complete and Time.get_ticks_msec() < deadline:
		complete = true
		for window in snapshot.windows:
			for pane in window.panes:
				complete = complete and FileAccess.file_exists(directory.path_join("pane-%d.json" % int(pane.id)))
		await process_frame
	await create_timer(.5).timeout
	print("RESTORE RECEIPTS COMPLETE: ", complete)
	for index in app.hosts.size():
		var host: Node = app.hosts[index]
		RenderingServer.force_draw()
		host.get_window().get_texture().get_image().save_png(directory.path_join("window-%d.png" % index))
	return complete


func observe_save(_app: Node) -> bool:
	var capture := await execute_cli(["rpc", "session.capture"])
	FileAccess.open(OS.get_environment("RESTORE_EVIDENCE").path_join("ordinary-capture.json"), FileAccess.WRITE).store_string(JSON.stringify(capture))
	if capture.code != 0: return false
	var text: Variant = JSON.parse_string("\n".join(capture.output))
	if not text is Dictionary or text.get("version") != 1 or not text.get("result", {}).get("text") is String: return false
	var token := OS.get_environment("GRAFFITTY_TOKEN")
	OS.set_environment("GRAFFITTY_TOKEN", "invalid-acceptance-capability")
	var rejected := await execute_cli(["checkpoint", "save", "--tag", "invalid"])
	OS.set_environment("GRAFFITTY_TOKEN", token)
	FileAccess.open(OS.get_environment("RESTORE_EVIDENCE").path_join("rejected-save.json"), FileAccess.WRITE).store_string(JSON.stringify(rejected))
	return rejected.code != 0 and "unauthorized" in str(rejected.output)
