extends "session-defaults.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var original: int = host.active_session_id
	var pid: int = terminal.get_shell_pid()
	var launch := directory.path_join("gui launch")
	var deleted := directory.path_join("deleted provider")
	DirAccess.make_dir_recursive_absolute(deleted)
	# Windows prevents removing a process's native cwd. Exercise a stale OSC 7
	# directory independently, through the real PTY, without a held cwd handle.
	await shell_receipt("[Console]::Write(([char]27)+']7;file:///%s'+([char]7)); " % deleted.replace("\\","/"))
	if not check(DirAccess.remove_absolute(deleted)==OK,"Delete real directory reported over OSC 7 without native cwd lock"):return
	var created: Array[int] = []
	for tab in [false,true]:
		host.focus_pane("%%%d" % original)
		await camera_at_rest()
		terminal = host.active_terminal()
		if not await new_shell(tab):return
		created.append(host.active_session_id)
		var result := await shell_receipt()
		check(same_path(result.cwd,launch),"Deleted provider cwd uses original GUI fallback for "+("tab" if tab else "split"))
	for id in created:host._close_terminal_pane(id)
	var deadline := Time.get_ticks_msec()+5000
	while host.sessions.size()!=1 and Time.get_ticks_msec()<deadline:await process_frame
	host.focus_pane("%%%d" % original)
	await camera_at_rest()
	terminal = host.active_terminal()
	var home := preload("res://graffitty/paths.gd").expand_home("~")
	await shell_receipt("Set-Location -LiteralPath '%s'; [Environment]::CurrentDirectory='%s'; [Console]::Write(([char]27)+']7;file:///%s'+([char]7)); " % [home.replace("'","''"),home.replace("'","''"),deleted.replace("\\","/")])
	if not check(DirAccess.remove_absolute(launch)==OK,"Delete original GUI directory after releasing native handles"):return
	for tab in [false,true]:
		host.focus_pane("%%%d" % original)
		await camera_at_rest()
		terminal = host.active_terminal()
		if not await new_shell(tab):return
		var result := await shell_receipt()
		check(same_path(result.cwd,home),"Removed source and GUI directory use owner home for "+("tab" if tab else "split"))
	overlay.hide()
	capture("session-fallback-home")
	check(host.sessions[original].term.get_shell_pid()==pid,"Directory fallback preserves original live shell")
