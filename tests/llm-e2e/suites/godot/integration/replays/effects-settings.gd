extends "input-routing.gd"
const Settings = preload("res://scenes/TerminalEffectsSettings.gd")

func open_settings() -> Node:
	for entry in host.menu_entries:
		if entry.label == "View::Effects…":
			host._run_menu_action(entry)
			await hold(.15)
			for child in host.get_children():
				if child is Settings: return child
	return null

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var pid: int = host.active_terminal().get_shell_pid()
	var previous: int = host.world.terminal_config.effects.typing_particles.amount
	var dialog := await open_settings()
	if not check(dialog != null and dialog.visible, "Effects opens through actual menu action"): return
	dialog.fields.amount.text = "-1"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(host.world.terminal_config.effects.typing_particles.amount == previous and "between" in dialog.status.text, "Invalid particle count preserves live settings")
	dialog.fields.amount.text = "6"
	dialog.fields.intensity.text = "1.5"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check("intensity (0–1) must be between" in dialog.status.text, "Out-of-range camera intensity rejected")
	dialog.fields.intensity.text = ".5"
	dialog.fields.maximum.text = "2"
	dialog.fields.enter.text = ".1"
	dialog.fields.hold.text = ".2"
	dialog.fields.leave.text = ".3"
	for style in ["smear", "blaze", "lightning"]:
		dialog.trail.select(Settings.TRAILS.find(style))
		dialog.get_ok_button().pressed.emit()
		await process_frame
		check(host.cursor_trail_style() == style, "Apply selects " + style + " in live renderer")
	for preset in ["dots", "fireworks", "flames", "glitter", "sparks"]:
		dialog.particles.select(Settings.PARTICLES.find(preset))
		dialog.get_ok_button().pressed.emit()
		await process_frame
		check(host.world.fx_cfg.frame(str(host.world.fx_cfg.behavior.active_state))["typing.particles"] == preset, "Apply selects " + preset + " particles")
	check(is_equal_approx(host.world.fx_cfg.frame(str(host.world.fx_cfg.behavior.active_state))["camera.zoom"], 1.5), "50 percent intensity with maximum 2 configures zoom 1.5")
	check(is_equal_approx(host.world.fx_idle_after, .2) and is_equal_approx(host.world.fx_leave_duration, .3), "Configured hold and decay reach active camera")
	overlay.hide()
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("effects-dialog.png"))
	dialog.fields.amount.text = "12"
	dialog.canceled.emit()
	await process_frame
	check(host.world.terminal_config.effects.typing_particles.amount == 6, "Cancel discards unapplied effect changes")
	dialog = await open_settings()
	check(float(dialog.fields.intensity.text) == .5 and float(dialog.fields.maximum.text) == 2.0, "Reopening retains applied camera controls")
	var scroll: ScrollContainer = dialog.grid.get_parent()
	scroll.scroll_vertical = int(dialog.grid.size.y)
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("effects-dialog-bottom.png"))
	dialog.canceled.emit()
	await process_frame
	check(host.active_terminal().get_shell_pid() == pid, "Effect edits preserve original shell PID")
