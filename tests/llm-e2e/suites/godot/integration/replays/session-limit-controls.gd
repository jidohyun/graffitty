extends "launch-policy-seed.gd"
func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var dialog:=await policy_dialog()
	var before: Dictionary=app.local_spawn_defaults.duplicate(true)
	for value in ["-1","134217729","1.5"]:
		dialog.limits.scrollback_bytes.edit.text=value
		await dialog_click(dialog.get_ok_button())
		check(app.local_spawn_defaults==before and "whole number" in dialog.status.text,"Invalid byte budget stays atomic: "+value)
	dialog.limits.scrollback_bytes.edit.text="0"
	dialog.limits.kitty_image_storage_mb.edit.text="0"
	dialog.integration.grab_focus()
	await hold(.2)
	overlay.hide()
	picture(host,"session-defaults-limits-hint")
	await dialog_click(dialog.get_ok_button())
	check(app.local_spawn_defaults.scrollback_bytes==0 and app.local_spawn_defaults.kitty_image_storage_mb==0,"Zero byte and image policies apply")
	dialog.canceled.emit()
