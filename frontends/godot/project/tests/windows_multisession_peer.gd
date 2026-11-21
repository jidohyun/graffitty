extends "windows_multisession_smoke.gd"
func run() -> void:
	root.size=Vector2i(1280,800)
	var recording:=preload("res://tests/windows_acceptance_recording.gd").new()
	recording.directory=directory.path_join("recording-B")
	DirAccess.make_dir_recursive_absolute(recording.directory)
	root.add_child(recording)
	var wrapper=load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args=PackedStringArray(["--workspace=B","--no-plugin"])
	root.add_child(wrapper)
	if not await wait_for(func():return wrapper.host!=null and wrapper.host.active_terminal()!=null):
		fail("Attached B presentation did not start")
		return
	var host: Node=wrapper.host
	var terminal: Node=host.active_terminal()
	if not await wait_for(func():return "DETACHED_RETAINED" in str(terminal.get_text(false).text)):
		fail("Attached B did not reconstruct retained output")
		return
	var pid: int=terminal.get_shell_pid()
	var camera: Vector2=host.workspace_view.navigation_center
	var focus: String=host.pane_focus
	FileAccess.open(directory.path_join("sibling-ready.json"),FileAccess.WRITE).store_string(JSON.stringify({"pid":pid,"frontend":OS.get_process_id()}))
	if not await wait_for(func():return "SURVIVOR_USABLE" in str(terminal.get_text(false).text),60):
		fail("Attached B did not receive post-close input")
		return
	terminal.send_text("Write-Output ('ATTACHED_'+'INPUT_DONE')\r")
	if not await wait_for(func():return "ATTACHED_INPUT_DONE" in str(terminal.get_text(false).text)):
		fail("Attached B cannot type after A closes")
		return
	if terminal.get_shell_pid()!=pid or host.pane_focus!=focus or host.workspace_view.navigation_center!=camera:
		fail("Attached B identity, focus or camera changed")
		return
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("attached-survivor.png"))
	FileAccess.open(directory.path_join("sibling-survived.json"),FileAccess.WRITE).store_string(JSON.stringify({"pid":pid,"input_confirmed":true}))
	if OS.get_environment("GRAFFITTY_MULTISESSION_FINAL_GUI")=="1":
		if not await wait_for(func():return FileAccess.file_exists(directory.path_join("close-final"))):
			fail("Controller did not request final GUI close")
			return
		if route=="tab-control":host.request_close_tab()
		elif route=="window-close":host.request_close_window()
		else:await close_pane(host)
	await create_timer(20).timeout
	fail("Attached B did not quit after final server-owned session closed")
