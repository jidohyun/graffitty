extends SceneTree
const Responsive := preload("res://scenes/input/ResponsiveDialogs.gd")
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
var failures: Array[String] = []

func _initialize() -> void:
	Background.install(self)
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(360, 640)
	var dialog := ConfirmationDialog.new()
	dialog.title = "Close window?"
	dialog.dialog_text = "Detach keeps the session running for later."
	dialog.ok_button_text = "Detach"
	root.add_child(dialog)
	var local_close := "--local-close" in OS.get_cmdline_user_args()
	var wide_width := 756 if local_close else 476
	var kill: Button
	if local_close:
		# Added after the shared policy first runs, as in the real close dialog.
		kill = dialog.add_button("Kill Server", false, "close_server")
		dialog.dialog_text = "Detach keeps every session running for later. Kill Server ends every session on this computer, including detached sessions."
	preload("res://scenes/DialogActionLayout.gd").popup_centered(dialog,
		Vector2i(640 if local_close else 420, 180 if local_close else 140))
	dialog.get_cancel_button().grab_focus()
	for locale in root.get_node("Localization").locales:
		TranslationServer.set_locale(locale)
		for area in [Rect2(12, 32, wide_width, 596), Rect2(12, 32, 336, 596), Rect2(12, 32, 616, 280 if local_close else 180), Rect2(12, 32, 296, 450 if local_close else 250)]:
			root.size = Vector2i(area.size + Vector2(24, 44))
			dialog.max_size = Vector2i(area.size)
			dialog.size = Vector2i(area.size.x, 160)
			for tick in 12:
				Responsive.fit_in_rect(dialog, area)
				await process_frame
			var actual := Rect2(Vector2(dialog.position), Vector2(dialog.size))
			check(area.grow(1).encloses(actual), "%s dialog exceeds usable viewport: %s, available %s" % [locale, actual, area])
			check(dialog.content_scale_factor >= 0.8, "%s confirmation text became too small: %s" % [locale, dialog.content_scale_factor])
			var flow := dialog.get_ok_button().get_parent() as HFlowContainer
			check(flow != null, "Actions use the shared wrapping layout")
			if flow == null: quit(1); return
			var rows := {}
			for button: Button in flow.get_children():
				var font := button.get_theme_font("font")
				var text_width := font.get_string_size(button.atr(button.text), HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x
				var padding := button.get_theme_stylebox("normal").get_minimum_size().x
				check(button.size.x >= text_width + padding - 1, "%s %s fits the complete label" % [locale, button.text])
				check(button.size.y >= 42, "Action keeps its minimum touch height")
				check(dialog.get_visible_rect().grow(1).encloses(button.get_global_rect()), "%s action stays inside the dialog" % locale)
				var y := roundi(button.position.y)
				if rows.has(y):
					check(absf(button.position.x - rows[y] - 8) <= 1, "Actions stay grouped with a compact gap")
				rows[y] = button.get_rect().end.x
			for edge in rows.values():
				check(absf(edge - flow.size.x) <= 1, "Every action row is aligned to the right")
			check(dialog.get_label().get_global_rect().end.y <= flow.global_position.y, "Warning text stays above the action rows")
			check(rows.size() == 1 if area.size.x == wide_width else true, "Wide dialogs keep actions in one row")
			check(rows.size() > 1 if area.size.x == 296 and local_close else true, "Narrow dialogs wrap whole buttons onto multiple rows")
			check(flow.get_child(-1) == dialog.get_cancel_button(), "Cancel remains last")
			check(dialog.get_cancel_button().has_focus(), "Resizing and translating preserve Cancel focus")
			var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
			if not evidence.is_empty() and locale in ["ko", "fr"] and roundi(area.size.x) in [wide_width, 336] and DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				RenderingServer.force_draw(false)
				root.get_texture().get_image().save_png(evidence.path_join("dialog-%s-%d.png" % [locale, area.size.x]))
		print("Checked right-aligned confirmation in ", locale)
	if local_close:
		var actions: Array[String] = []
		dialog.custom_action.connect(func(action): actions.append(action))
		kill.pressed.emit()
		check(actions == ["close_server"], "Reflowed custom action keeps its signal")
		dialog.get_cancel_button().grab_focus()
	var cancellations: Array[bool] = []
	dialog.canceled.connect(func(): cancellations.append(true))
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_SPACE
		event.pressed = pressed
		dialog.push_input(event, true)
		await process_frame
	check(cancellations.size() == 1 and not dialog.visible, "Keyboard activation of Cancel dismisses the dialog")
	var fitting := Responsive.new()
	root.add_child(fitting)
	fitting.watch(dialog)
	root.size = Vector2i(480, 800)
	dialog.popup_centered(Vector2i(420, 400))
	fitting.set_bottom_inset(400)
	for tick in 12: await process_frame
	check(dialog.position.y + dialog.size.y <= 388, "Inset notification fits the dialog above the keyboard")
	root.size = Vector2i(360, 640)
	fitting.set_bottom_inset(180)
	for tick in 12: await process_frame
	check(dialog.position.x >= 12 and dialog.position.x + dialog.size.x <= 348 and dialog.position.y + dialog.size.y <= 448, "Rotation and a new inset refit without frame polling")
	fitting.queue_free()
	dialog.queue_free()
	await process_frame
	print("RESPONSIVE_DIALOGS_PASS" if failures.is_empty() else "RESPONSIVE_DIALOGS_FAIL")
	quit(0 if failures.is_empty() else 1)
