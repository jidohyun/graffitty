extends "session-defaults.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var dialog := await defaults_dialog()
	var before: Dictionary = app.local_spawn_defaults.duplicate(true)
	dialog.shell.text = "missing-acceptance-executable"
	dialog.get_ok_button().pressed.emit()
	check("does not exist" in dialog.status.text and app.local_spawn_defaults==before,"Missing shell leaves defaults unchanged")
	dialog.shell.text = "pwsh.exe"
	dialog.directory.text = directory.path_join("missing")
	dialog.get_ok_button().pressed.emit()
	check("existing absolute" in dialog.status.text and app.local_spawn_defaults==before,"Missing cwd leaves defaults unchanged")
	dialog.directory.text = directory.path_join("configured directory")
	dialog.environment.text = "codex_thread_id=blocked"
	dialog.get_ok_button().pressed.emit()
	check("managed" in dialog.status.text and app.local_spawn_defaults==before,"Case-insensitive reserved Windows environment rejected")
	dialog.environment.text = "ACCEPTANCE_DEFAULT_LITERAL=$(not_a_command); café 한글"
	dialog.arguments.text = "-NoLogo\n-NoProfile"
	dialog.get_ok_button().pressed.emit()
	await hold(.25)
	check(dialog.status.text=="Defaults applied to future local sessions.","Literal fields apply through corrected dialog")
	overlay.hide()
	capture("session-defaults-dialog")
	var scroll: ScrollContainer = dialog.environment.get_parent().get_parent()
	scroll.scroll_vertical = int(dialog.environment.get_parent().size.y)
	await hold(.1)
	capture("session-defaults-dialog-bottom")
	dialog.canceled.emit()
	await process_frame
