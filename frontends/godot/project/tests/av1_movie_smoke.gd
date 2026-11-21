extends SceneTree
var frame := 0
var panel: ColorRect


func _initialize() -> void:
	root.unfocusable = true
	panel = ColorRect.new()
	panel.color = Color(0.1, 0.3, 0.8)
	root.add_child.call_deferred(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_dt: float) -> bool:
	frame += 1
	var writer := Engine.get_singleton("GraffittyMovieWriter")
	if frame == 10:
		writer.set_recording(true)
	if frame == 30:
		writer.set_recording(false)
		print("AV1_CAPTURE_FRAMES=", writer.frames_written())
		quit()
	return false
