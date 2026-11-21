extends CanvasLayer
## Own hover hit-testing while the gesture owner retains click focus/input.
## Handling _input alone is insufficient: Godot updates hover before _input.
var shield := Control.new()

func _init() -> void:
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.POINTER_CAPTURE
	hide()
	shield.name = "PointerHoverCapture"
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	shield.mouse_force_pass_scroll_events = false
	shield.focus_mode = Control.FOCUS_NONE
	shield.add_to_group(&"touch_chrome")
	add_child(shield)

func _ready() -> void:
	shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
