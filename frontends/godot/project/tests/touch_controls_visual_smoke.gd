extends SceneTree
## Renders the touch key strip and floating buttons in their visible states and
## saves one PNG for visual inspection of the mod-painted faces.
## Needs a real renderer: --position -32000,-32000, not --headless.
##     godot --path . --script tests/touch_controls_visual_smoke.gd -- --out=/tmp/x.png

const Floating := preload("res://scenes/input/FloatingButtons.gd")
const Icons := preload("res://scenes/PaneIcons.gd")
const Face := preload("res://scenes/input/TouchFace.gd")
const KeyBar := preload("res://scenes/input/TouchKeyBar.gd")


func floating_button(icon: Texture2D, face: String, disabled := false) -> Button:
	var button := Button.new()
	button.icon = icon
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = Floating.SIZE
	button.focus_mode = Control.FOCUS_NONE
	Floating._style(button)
	button.disabled = disabled
	Face.attach(button, {"part": "button", "button": face})
	return button


func _initialize() -> void:
	root.size = Vector2i(660, 288)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var backdrop := ColorRect.new()
	backdrop.color = Color("1b1d22")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(backdrop)
	var bars := []
	# The last rows: a phone-width strip scrolled to its navigation keys, and a
	# wide strip slid right until its left end is at mid-screen.
	for state in ["plain", "armed", "locked", "scrolled", "slid"]:
		var bar: PanelContainer = KeyBar.new()
		# The strip pins itself to the bottom of its parent, as on a screen.
		var screen := Control.new()
		screen.position = Vector2(8, 8 + bars.size() * 44)
		screen.size = Vector2(360 if state == "scrolled" else 640, bar.HEIGHT)
		root.add_child(screen)
		screen.add_child(bar)
		bars.append([bar, state])
	var row := HBoxContainer.new()
	row.position = Vector2(8, 228)
	row.add_theme_constant_override("separation", 8)
	root.add_child(row)
	row.add_child(floating_button(Icons.keyboard(), "keyboard"))
	row.add_child(floating_button(Icons.microphone(), "microphone"))
	row.add_child(floating_button(Icons.stop(), "stop"))
	row.add_child(floating_button(Icons.microphone(), "microphone", true))
	var recording := floating_button(Icons.microphone(), "microphone")
	recording.modulate = Color("ff6688")
	row.add_child(recording)
	var text_size: Button = load("res://scenes/input/TextSizeButton.gd").new()
	Floating._style(text_size)
	text_size.custom_minimum_size = Vector2(104, 52)
	row.add_child(text_size)
	for i in 4: await process_frame
	# A strip's _ready hides it, and runs only once the tree has started.
	for pair in bars: pair[0].show()
	for i in 2: await process_frame
	for pair in bars:
		var bar = pair[0]
		match pair[1]:
			"scrolled": bar.slide_strip(-10000)
			"slid": bar.slide_strip(10000)
			"armed": bar.cycle_modifier("ctrl")
			"locked":
				for key in ["alt", "shift"]:
					bar.cycle_modifier(key)
					bar.cycle_modifier(key)
	for i in 8: await process_frame
	var out := "/tmp/touch-controls.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.substr(6)
	root.get_viewport().get_texture().get_image().save_png(out)
	print("TOUCH_CONTROLS_CAPTURED ", out)
	quit(0)
