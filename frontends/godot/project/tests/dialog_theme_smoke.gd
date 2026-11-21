extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	TranslationServer.set_locale("en")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.gui_embed_subwindows = true
	root.size = Vector2i(1000, 480)
	var backdrop := ColorRect.new()
	backdrop.color = Color("15191f")
	backdrop.size = Vector2(1000, 480)
	root.add_child(backdrop)
	var dialog := ConfirmationDialog.new()
	dialog.title = "Close chromium?"
	dialog.dialog_text = "Closing ends this chromium session and discards unsaved page state."
	dialog.ok_button_text = "Close chromium"
	root.add_child(dialog)
	dialog.popup_centered(Vector2i(780, 190))
	dialog.content_scale_factor = 1
	for i in 12: await process_frame
	assert(dialog.theme.get_stylebox("normal", "Button").corner_radius_top_left == 10)
	assert(dialog.theme.get_stylebox("panel", "AcceptDialog").corner_radius_bottom_left == 16)
	assert(dialog.get_ok_button().size.y >= 42)
	for kind in ["CheckBox", "CheckButton"]:
		# Base Button text and toggle indicators must resolve matching padding.
		for state in ["normal", "hover", "pressed", "disabled", "hover_pressed", "focus"]:
			assert(dialog.theme.has_stylebox(state, kind), "%s needs its own %s style" % [kind, state])
			var expected := ThemeDB.get_default_theme().get_stylebox(state, kind)
			var actual := dialog.theme.get_stylebox(state, kind)
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				assert(actual.get_margin(side) == expected.get_margin(side))
		assert(dialog.theme.get_constant("h_separation", kind) >= 8)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-dialog-theme.png")
	dialog.queue_free()
	await process_frame
	print("PASS rounded dialog and keyboard-focus theme")
	quit()
