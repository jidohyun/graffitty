extends "main-area-tiling.gd"


func verify_pwd(expected: String, tag: String) -> void:
	var path := OS.get_environment("XDG_STATE_HOME").path_join("graffitty-cwd-%d-%s" % [OS.get_process_id(), tag])
	if OS.get_name() == "Windows":
		await type("[IO.File]::WriteAllText('%s', (Get-Location).Path){enter}" % path.replace("'", "''"))
	else:
		# /bin/sh has no shell integration to report its logical directory, so
		# the owner can only follow the resolved one: compare physical paths.
		await type("pwd -P; pwd -P > '%s'{enter}" % path)
		var resolved: Array = []
		if OS.execute("/bin/sh", ["-c", "cd '%s' && pwd -P" % expected.replace("'", "'\\''")], resolved) == 0:
			expected = str(resolved[0]).strip_edges()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path) and not FileAccess.get_file_as_string(path).is_empty():
			break
		await process_frame
	var actual := FileAccess.get_file_as_string(path).strip_edges() if FileAccess.file_exists(path) else ""
	if OS.get_name() == "Windows": actual = actual.replace("\\", "/")
	check(actual == expected.replace("\\", "/"), "%s: shell pwd is %s (expected %s)" % [tag, actual, expected])
	DirAccess.remove_absolute(path)
	await camera_at_rest()


func play() -> void:
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	var initial: String = host.application.initial_directory
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cwd="):
			check(initial == arg.substr(6), "--cwd overrides the configured startup directory")
	await verify_pwd(initial, "initial")
	var alpha: String = host.pane_focus
	var alpha_id := int(alpha.substr(1))
	var pid: int = host.sessions[alpha_id].term.get_shell_pid()
	var base := OS.get_environment("XDG_STATE_HOME")
	var directory := base.path_join("graffitty pane cwd %d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	await type("cd '%s'{enter}" % directory)
	await camera_at_rest()
	var beta := await add_window(alpha)
	if beta.is_empty():
		return
	await type("cd /{enter}")
	await camera_at_rest()
	await say("Split unfocused ALPHA: inherit its shell directory")
	var child := await add_window(alpha)
	if child.is_empty():
		return
	await verify_pwd(directory, "origin")
	check(host.application.initial_directory == initial, "Changing cwd preserves the initial fallback")
	if OS.get_name() == "Windows":
		# Windows locks a process's current directory against deletion. Move both
		# shells out, leaving ALPHA's last OSC 7 report stale to test validation.
		await type("cd '%s'{enter}" % initial.replace("'", "''"))
		host.sessions[alpha_id].term.send_text("$env:GRAFFITTY_SHELL_SKIP_CWD='1'; cd '%s'; [Environment]::CurrentDirectory=(Get-Location).Path\r" % initial.replace("'", "''"))
		await hold(0.5)
	check(DirAccess.remove_absolute(directory) == OK, "The reported directory no longer exists")
	await camera_at_rest()
	await say("Split ALPHA after its directory is deleted: use the startup directory")
	var fallback := await add_window(alpha, "v")
	if fallback.is_empty():
		return
	await verify_pwd(initial, "fallback")
	check(host.sessions[alpha_id].term.get_shell_pid() == pid, "Original shell survives every split")
	check(host.sessions.has(int(beta.substr(1))), "Other pane survives")
