extends Button
## One movable pill with two tap targets. FloatingButtons owns the gesture,
## so holding/dragging never fires a size change on release.
signal stepped(direction: int)
var direction := 1
var _pressed := false


func _init() -> void:
	name = "TextSizeButton"
	custom_minimum_size = Vector2(104, 52)
	tooltip_text = "Text size · hold to move"
	# The − | + glyphs are this control's face in the touch-controls mod.
	preload("res://scenes/input/TouchFace.gd").attach(self, {"part": "button", "button": "text_size", "width": custom_minimum_size.x, "height": custom_minimum_size.y})
	resized.connect(func(): preload("res://scenes/input/TouchFace.gd").update(self, {"width": size.x, "height": size.y}))
	# Remember the half before FloatingButtons consumes this same event.
	gui_input.connect(func(event: InputEvent):
		if _pressed: return
		if (event is InputEventScreenTouch and event.pressed) or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.device != -1):
			_pressed = true
			direction = -1 if event.position.x < size.x / 2 else 1)


func activate() -> void:
	_pressed = false
	stepped.emit(direction)


func cancel() -> void:
	_pressed = false
