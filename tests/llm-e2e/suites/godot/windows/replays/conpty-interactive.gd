extends "powershell.gd"

func play() -> void:
	check(OS.get_name() == "Windows", "Native Windows ConPTY input route")
	if OS.get_name() != "Windows": return
	var runtime := OS.get_environment("XDG_STATE_HOME").path_join("loaded-conpty.json")
	var inspector: String = ProjectSettings.globalize_path(get_script().resource_path.get_base_dir().path_join("runtime-modules.py"))
	var output: Array = []
	var exit_code := OS.execute("python", [inspector, OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR"), runtime], output, true)
	print("[loaded ConPTY] ", output)
	if not check(exit_code == 0 and FileAccess.file_exists(runtime), "The actual server's loaded ConPTY module is recorded"): return
	var module: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(runtime))
	check(module.file_version[0] == 1 and module.file_version[1] == 25, "The loaded ConPTY runtime is version 1.25")
	var fixture: String = get_script().resource_path.get_base_dir().path_join("conpty_probe.py")
	fixture = ProjectSettings.globalize_path(fixture)
	var pid: int = host.sessions[host.active_session_id].term.get_shell_pid()
	for shell in ["powershell.exe", "pwsh.exe"]:
		await say("Query colors and receive wheel input through " + shell)
		var result_path := OS.get_environment("XDG_STATE_HOME").path_join(shell + "-conpty.json")
		var command := "& '%s' -NoLogo -NoProfile -Command \"python '%s' '%s'\"; Write-Output ('SHELL_DONE=' + '%s'){enter}" % [shell, fixture.replace("'", "''"), result_path.replace("'", "''"), shell]
		await type(command)
		var ready_deadline := Time.get_ticks_msec() + 15000
		while not FileAccess.file_exists(result_path + ".ready") and Time.get_ticks_msec() < ready_deadline:
			await process_frame
		check(FileAccess.file_exists(result_path + ".ready"), shell + " enables VT input and mouse reporting")
		if not FileAccess.file_exists(result_path + ".ready"):
			print("[windows terminal] ", text())
			return
		await create_timer(.3).timeout
		await camera_at_rest()
		await point_at(root.get_visible_rect().size * Vector2(.5, .55))
		# One wheel event: repeated events can race a successful probe's exit
		# and become literal prompt input after the application resets mouse mode.
		await tap(MOUSE_BUTTON_WHEEL_DOWN)
		var deadline := Time.get_ticks_msec() + 15000
		while not FileAccess.file_exists(result_path) and Time.get_ticks_msec() < deadline:
			await process_frame
		check(FileAccess.file_exists(result_path), shell + " probe completed")
		if not FileAccess.file_exists(result_path):
			print("[windows terminal] ", text())
			continue
		var result = JSON.parse_string(FileAccess.get_file_as_string(result_path))
		check(result is Dictionary, shell + " probe evidence is valid JSON")
		if result is Dictionary:
			check(result.get("colors", false), shell + " receives OSC 10 and 11 color replies")
			check(result.get("wheel", false), shell + " receives SGR wheel input")
			print("[windows evidence] ", result_path, " ", JSON.stringify(result))
		await create_timer(.3).timeout
		var finish := FileAccess.open(result_path + ".finish", FileAccess.WRITE)
		finish.store_string("finish")
		finish.close()
		await expect_output("SHELL_DONE=" + shell, shell + " exits back to the owning shell")
		# A profile's prompt may launch subprocesses before PSReadLine starts.
		# The completion marker precedes that prompt, not its readiness for keys.
		await create_timer(1.0).timeout
	check(host.sessions[host.active_session_id].term.get_shell_pid() == pid, "Console probes preserve the owning shell")
