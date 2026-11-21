extends RefCounted
## Keep complete action buttons together at the right edge, wrapping by button.

static func apply(dialog: AcceptDialog) -> HFlowContainer:
	var row := dialog.get_ok_button().get_parent()
	var flow := row as HFlowContainer
	if flow == null:
		flow = HFlowContainer.new()
		flow.name = "DialogActions"
		flow.alignment = FlowContainer.ALIGNMENT_END
		flow.last_wrap_alignment = FlowContainer.LAST_WRAP_ALIGNMENT_END
		flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		row.add_child(flow)
		# The row can resize while its dialog is being freed; never capture
		# the dialog itself, or the deferred call receives a freed object.
		var owner: WeakRef = weakref(dialog)
		flow.minimum_size_changed.connect(func():
			var target := owner.get_ref() as AcceptDialog
			if target == null or not target.visible: return
			target.child_controls_changed()
			# A changed row count needs new content/button rectangles even if
			# the dialog's outer size already has enough room.
			target.notification(Window.NOTIFICATION_WM_SIZE_CHANGED), CONNECT_DEFERRED)
	else:
		row = flow.get_parent()
	var first := 0
	for child in row.get_children():
		if child == flow: continue
		if child is Button:
			var prepend := child.get_index() < flow.get_index()
			child.reparent(flow, false)
			if prepend:
				flow.move_child(child, first)
				first += 1
		elif child is Control:
			# AcceptDialog retains references to its spacers and may show them
			# when a button's visibility changes. Exclude them from layout.
			child.set_as_top_level(true)
			child.hide()
	for button in flow.get_children():
		button.autowrap_mode = TextServer.AUTOWRAP_OFF
		button.size_flags_horizontal = Control.SIZE_SHRINK_END
		button.custom_minimum_size = Vector2(
			dialog.get_theme_constant("buttons_min_width", "AcceptDialog"),
			dialog.get_theme_constant("buttons_min_height", "AcceptDialog"))
	if dialog is ConfirmationDialog:
		flow.move_child(dialog.get_cancel_button(), -1)
	return flow


static func popup_centered(dialog: AcceptDialog, logical_size: Vector2i) -> void:
	# Let the label and flow measure at the requested width before enforcing
	# their minimum height; their initial narrow layout can be much taller.
	var wrap := dialog.wrap_controls
	dialog.wrap_controls = false
	var wanted := Vector2(logical_size) * dialog.content_scale_factor
	if dialog.is_embedded():
		wanted = wanted.min((dialog.get_parent().get_viewport().get_visible_rect().size - Vector2(24, 44)).max(Vector2.ONE))
	dialog.popup_centered(Vector2i(wanted.ceil()))
	await dialog.get_tree().process_frame
	if not is_instance_valid(dialog): return
	dialog.wrap_controls = wrap
	if not dialog.visible: return
	var previous := dialog.size
	dialog.size.y = ceili(maxf(logical_size.y, dialog.get_contents_minimum_size().y) * dialog.content_scale_factor)
	dialog.position.y += (previous.y - dialog.size.y) / 2
