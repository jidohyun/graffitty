extends "terminal-tools.gd"
const Defaults = preload("res://scenes/TerminalSessionDefaults.gd")
var receipt_number := 0

func _initialize() -> void:
	var evidence := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	for child in ["gui launch", "source directory", "configured directory", "split directory"]:
		DirAccess.make_dir_recursive_absolute(evidence.path_join(child))
	OS.set_environment("GRAFFITTY_INITIAL_PWD",evidence.path_join("gui launch"))
	super._initialize()

func defaults_dialog() -> Node:
	await menu("Shell::Session Defaults…")
	for child in host.get_children():
		if child is Defaults: return child
	return null

func shell_receipt(prefix := "") -> Dictionary:
	receipt_number += 1
	var path := directory.path_join("shell-%d.json" % receipt_number)
	await type(prefix + "[ordered]@{cwd=(Get-Location).Path; literal=$env:ACCEPTANCE_DEFAULT_LITERAL; pid=$PID; version=$PSVersionTable.PSVersion.Major} | ConvertTo-Json -Compress | Set-Content -LiteralPath '%s' -Encoding utf8{enter}" % path.replace("'","''"))
	if not check(await wait_file(path), "Actual shell receipt %d" % receipt_number): return {}
	return JSON.parse_string(FileAccess.get_file_as_string(path).trim_prefix("\ufeff"))

func cd_command(path: String) -> String:
	return "Set-Location -LiteralPath '%s'; [Console]::Write(([char]27)+']7;file:///%s'+([char]7)); " % [path.replace("'","''"),path.replace("\\","/")]

func same_path(a: String,b: String) -> bool:
	return a.replace("\\","/").to_lower()==b.replace("\\","/").to_lower()

func new_shell(tab: bool) -> bool:
	var old: int = host.active_session_id
	if tab: host.world.create_terminal_tab()
	else: host.create_terminal_window("","h")
	var deadline := Time.get_ticks_msec()+10000
	while (host.active_session_id==old or host.active_terminal()==null or host.active_terminal().get_shell_pid()<=0) and Time.get_ticks_msec()<deadline: await process_frame
	await camera_at_rest()
	terminal = host.active_terminal()
	return check(host.active_session_id!=old,"New independent %s shell" % ("tab" if tab else "split"))

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var original: int = host.active_session_id
	var pid: int = terminal.get_shell_pid()
	var initial := await shell_receipt()
	check(same_path(initial.cwd,directory.path_join("gui launch")),"Initial shell uses GUI launch directory")
	var source := directory.path_join("source directory")
	var first := await shell_receipt(cd_command(source)+"$env:ACCEPTANCE_DEFAULT_LITERAL='ORIGINAL'; ")
	var dialog := await defaults_dialog()
	if not check(dialog!=null,"Session Defaults opens through real Shell menu"): return
	var unchanged: Dictionary = app.local_spawn_defaults.duplicate(true)
	dialog.shell.text = directory.path_join("missing-shell.exe")
	dialog.get_ok_button().pressed.emit()
	check("does not exist" in dialog.status.text and app.local_spawn_defaults==unchanged,"Missing executable rejected atomically")
	dialog.shell.text = "pwsh.exe"
	dialog.arguments.text = "-NoLogo\n-NoProfile"
	dialog.directory.text = directory.path_join("missing directory")
	dialog.get_ok_button().pressed.emit()
	check("existing absolute" in dialog.status.text and app.local_spawn_defaults==unchanged,"Missing directory rejected atomically")
	dialog.directory.text = directory.path_join("configured directory")
	dialog.environment.text = "GRAFFITTY_SESSION=forbidden"
	dialog.get_ok_button().pressed.emit()
	check("managed" in dialog.status.text and app.local_spawn_defaults==unchanged,"Protected environment rejected atomically")
	dialog.environment.text = "ACCEPTANCE_DEFAULT_LITERAL=$(not_a_command); café 한글"
	dialog.get_ok_button().pressed.emit()
	check(dialog.status.text=="Defaults applied to future local sessions.","Literal new-session defaults applied")
	overlay.hide()
	capture("session-defaults-dialog")
	dialog.canceled.emit()
	await process_frame
	if not await new_shell(true): return
	var next := await shell_receipt()
	check(same_path(next.cwd,source) and next.literal=="$(not_a_command); café 한글" and int(next.pid)!=pid,"New tab inherits live source cwd and literal new environment")
	dialog = await defaults_dialog()
	dialog.environment.text = "ACCEPTANCE_DEFAULT_LITERAL=SPLIT_LITERAL"
	dialog.get_ok_button().pressed.emit()
	dialog.canceled.emit()
	await process_frame
	if not await new_shell(false): return
	var split := await shell_receipt()
	check(same_path(split.cwd,source) and split.literal=="SPLIT_LITERAL","Split uses new defaults and source cwd")
	var moved := directory.path_join("split directory")
	await shell_receipt(cd_command(moved))
	if not await new_shell(false): return
	var descendant := await shell_receipt()
	check(same_path(descendant.cwd,moved),"Descendant split inherits changed live cwd")
	host.focus_pane("%%%d" % original)
	await camera_at_rest()
	terminal = host.active_terminal()
	var retained := await shell_receipt()
	check(retained.pid==first.pid and retained.literal=="ORIGINAL" and same_path(retained.cwd,source),"Existing original shell retains PID, environment and cwd")
	capture("session-defaults-result")
	check(host.sessions[original].term.get_shell_pid()==pid,"All default edits preserve original process")
