extends LineEdit
## Password field: masked until its eye button is pressed, and masked again
## whenever it leaves the screen.
const TOGGLE_WIDTH := 40
static var _spacer: ImageTexture
var toggle := Button.new()
var revealed := false:
	set(value):
		revealed = value
		secret = not value
		toggle.icon = hide_icon() if value else show_icon()
		toggle.tooltip_text = "Hide password" if value else "Show password"


## Loaded on use, not preloaded: a script is compiled before a fresh checkout's
## first import, when an image has no loader yet, and that fails a release build.
static func show_icon() -> Texture2D:
	return load("res://scenes/icons/eye.svg")


static func hide_icon() -> Texture2D:
	return load("res://scenes/icons/eye-off.svg")


func _init() -> void:
	# `secret` only masks the text. The password keyboard also stops Android
	# suggesting or learning it, and stays while the text is shown.
	virtual_keyboard_type = KEYBOARD_TYPE_PASSWORD
	# A blank right icon keeps typed text out from under the button.
	if _spacer == null:
		_spacer = ImageTexture.create_from_image(Image.create_empty(TOGGLE_WIDTH - 8, 1, false, Image.FORMAT_RGBA8))
	right_icon = _spacer
	toggle.flat = true
	# Never takes focus, so a tap leaves the caret and Android keyboard alone.
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	toggle.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toggle.expand_icon = true
	toggle.add_theme_constant_override("icon_max_width", 20)
	toggle.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	toggle.offset_left = -TOGGLE_WIDTH
	toggle.pressed.connect(func(): revealed = not revealed)
	add_child(toggle)
	revealed = false
	visibility_changed.connect(_conceal_when_hidden)


# Closing a dialog hides its window, which does not notify the controls inside.
func _enter_tree() -> void:
	get_window().visibility_changed.connect(_conceal_when_hidden)


func _exit_tree() -> void:
	get_window().visibility_changed.disconnect(_conceal_when_hidden)


func _conceal_when_hidden() -> void:
	if not is_visible_in_tree() or not get_window().visible: revealed = false
