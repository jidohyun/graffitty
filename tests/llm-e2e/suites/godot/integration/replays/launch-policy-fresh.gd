extends "launch-policy-seed.gd"
func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	connection=host.session_backend.connection
	var shared:=OS.get_environment("GRAFFITTY_REPLAY_SHARED_EVIDENCE")
	var seed: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(shared.path_join("seed.json")))
	check(OS.get_process_id()!=int(seed.frontend_pid),"Checkpoint reconstructs in a genuinely fresh frontend process")
	var stop_effects: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	for before in seed.panes:
		var id:=int(before.id)
		check(host.sessions.has(id) and host.sessions[id].term.get_shell_pid()==int(before.pid),"Fresh frontend retains actual shell %d identity" % id)
		for after in connection.topology.panes:
			if int(after.id)==id:
				check(after.limits.keys().size()==before.limits.keys().size() and before.limits.keys().all(func(key):return after.limits.has(key) and int(after.limits[key])==int(before.limits[key])),"Fresh checkpoint restores resolved limits for pane %d" % id)
	host.focus_pane("%%%d" % int(seed.large))
	await camera_at_rest()
	terminal=host.active_terminal()
	var expected:=FileAccess.get_file_as_string(shared.path_join("retained-history.txt"))
	var actual: String=terminal.get_text(true).text
	check(actual==expected,"Large history reconstructs exactly without invented blank rows")
	FileAccess.open(directory.path_join("reconstructed-history.txt"),FileAccess.WRITE).store_string(actual)
	host.focus_pane("%%%d" % int(seed.zero))
	await camera_at_rest()
	terminal=host.active_terminal()
	check(terminal.image_placements().is_empty() and terminal.get_ui_state().scroll_total==terminal.get_ui_state().scroll_page,"Fresh zero-policy viewport contains neither forbidden images nor scrollback")
	await zero_image("fresh","")
	await type("Write-Output 'FRESH_POLICY_INPUT_ALIVE_152'{enter}")
	await until(func():return output_line("FRESH_POLICY_INPUT_ALIVE_152"),"New typed input works in retained shell after fresh attachment")
	picture(host,"fresh-policy-whole-ui")
	stop_effects.call()
