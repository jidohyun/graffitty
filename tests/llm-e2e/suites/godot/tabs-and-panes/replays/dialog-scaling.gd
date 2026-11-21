extends "../../../../replay/replay.gd"
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")

func client_needs_window() -> bool:
	return true

func play() -> void:
	root.content_scale_size = Vector2i.ZERO
	app.configure_window_scale(root)
	await camera_at_rest()
	var native_scale: float = root.content_scale_factor
	for embedded in [false, true]:
		if embedded: root.gui_embed_subwindows = true
		else: native_subwindows()
		host.rename_pane(host.pane_focus)
		await hold(.15)
		var dialog: ConfirmationDialog = host.get_node("RenameDialog")
		var field: LineEdit = dialog.find_child("Title", true, false)
		check(dialog.is_embedded() == embedded, "Exercise %s dialog" % ["embedded" if embedded else "native"])
		check(is_equal_approx(dialog.content_scale_factor, 1.0 if embedded else native_scale), "Dialog uses display scaling exactly once")
		check(field.get_theme_font_size("font_size") == 20 and dialog.get_ok_button().get_theme_font_size("font_size") == 20, "Rename input and buttons use 20-point text")
		for label in dialog.find_children("*", "Label", true, false):
			check(label.get_theme_font_size("font_size") == 20, "Dialog labels use the shared readable size")
		var screen_height: float = ScreenSpace.of(field, Vector2(0, field.size.y)).distance_to(ScreenSpace.of(field, Vector2.ZERO))
		check(absf(screen_height / field.size.y - native_scale) < .05, "Dialog controls have the same physical scale as the main view (actual %.2f, expected %.2f)" % [screen_height / field.size.y, native_scale])
		if not embedded and DisplayServer.get_name() != "headless":
			DirAccess.make_dir_recursive_absolute("res://build")
			dialog.get_texture().get_image().save_png("res://build/dialog-scaling.png")
		if embedded and DisplayServer.get_name() != "headless":
			root.get_texture().get_image().save_png("res://build/dialog-scaling-embedded.png")
		for width in [500, 700]:
			dialog.size.x = int(width * (1.0 if embedded else native_scale))
			await hold(.1)
			check(field.get_theme_font_size("font_size") == 20, "Resizing the dialog does not shrink its text")
		if not embedded:
			dialog.content_scale_factor = .5
			dialog.dpi_changed.emit()
			check(is_equal_approx(dialog.content_scale_factor, native_scale), "Display DPI changes refresh dialog scale")
		dialog.hide()
		await hold(.1)
		# Dialogs created by other features receive the policy automatically too.
		var other := AcceptDialog.new()
		other.title = "Shared dialog policy"
		host.add_child(other)
		var dynamic := LineEdit.new()
		other.add_child(dynamic)
		check(dynamic.get_theme_font_size("font_size") == 20, "Dynamically added fields inherit the dialog font size")
		check(is_equal_approx(other.content_scale_factor, 1.0 if embedded else native_scale), "Other dialog types share the same DPI policy")
		other.queue_free()
	native_subwindows()
