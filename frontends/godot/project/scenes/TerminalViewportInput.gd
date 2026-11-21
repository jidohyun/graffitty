extends RefCounted
## A terminal viewport survives its pane controls and can be temporarily enabled
## for pointer input without giving its shell keyboard focus.
const POINTER_INSIDE := &"terminal_pointer_inside"


static func set_pointer_inside(viewport: SubViewport, inside: bool) -> void:
	# Disabled viewports reject exit notifications. Never enter one until its
	# pointer event is actually forwarded with input temporarily enabled.
	if viewport.gui_disable_input or viewport.get_meta(POINTER_INSIDE, false) == inside:
		return
	viewport.set_meta(POINTER_INSIDE, inside)
	if inside:
		viewport.notify_mouse_entered()
	else:
		viewport.notify_mouse_exited()


static func set_disabled(viewport: SubViewport, disabled: bool) -> void:
	if viewport.gui_disable_input == disabled:
		return
	# Godot's input-disable setter implicitly clears mouse presence and hover.
	# Clear our notification state at the same time, including on focus changes.
	if disabled:
		viewport.set_meta(POINTER_INSIDE, false)
	viewport.gui_disable_input = disabled
