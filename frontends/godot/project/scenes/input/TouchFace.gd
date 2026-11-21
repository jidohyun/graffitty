extends RefCounted
## The face of a touch control, painted by the bundled `touch-controls` mod.
## The button stays native: input, holds, drags, latches and its background
## chrome.
##
## Its own text and icon remain set, only invisible, so it measures and lays
## out exactly as before; the mod draws on top and never takes input.
##
## The face follows the button's draw state with the colors the button itself
## would have used for its text or icon in that state, read before hiding them.

const MOD := "touch-controls"
const MODES := {
	BaseButton.DRAW_NORMAL: "normal", BaseButton.DRAW_HOVER: "hover",
	BaseButton.DRAW_PRESSED: "pressed", BaseButton.DRAW_HOVER_PRESSED: "hover_pressed",
	BaseButton.DRAW_DISABLED: "disabled",
}


## Attach a face to `button` with `props` (see mods/touch-controls/main.js).
## `text` picks the button's text colors for the palette, else its icon colors.
static func attach(button: Button, props: Dictionary, text := false) -> Control:
	var palette := {}
	for mode in MODES.values():
		var name: String = ("font_" + ("" if mode == "normal" else mode + "_") + "color") if text else ("icon_" + mode + "_color")
		palette[mode] = hex(button.get_theme_color(name, "Button"))
	hide_native(button)
	var initial := props.duplicate()
	initial.merge({"palette": palette, "mode": MODES.get(button.get_draw_mode(), "normal")}, false)
	var view := preload("res://scenes/mods/EmbeddedMod.gd").create(MOD, initial)
	view.name = "Face"
	view.set_meta(&"face_props", initial)
	button.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Every state change redraws the button; mirror it on the next idle frame.
	button.draw.connect(func(): _follow.call_deferred(button))
	return view


static func _follow(button: Button) -> void:
	if is_instance_valid(button): update(button, {"mode": MODES.get(button.get_draw_mode(), "normal")})


static func face(button: Button) -> Control:
	return button.get_node_or_null("Face")


## Merge `changes` into the face's props and repaint if anything changed.
static func update(button: Button, changes: Dictionary) -> void:
	var view := face(button)
	if view == null: return
	var props: Dictionary = view.get_meta(&"face_props", {})
	var next := props.duplicate()
	next.merge(changes, true)
	if next == props: return
	view.set_meta(&"face_props", next)
	preload("res://scenes/mods/EmbeddedMod.gd").set_props(view, next)
	view.render_now()


## The button's own label and icon stay for layout and accessibility, unseen.
static func hide_native(button: Button) -> void:
	for state in ["", "_hover", "_pressed", "_hover_pressed", "_focus", "_disabled"]:
		button.add_theme_color_override("font" + state + "_color", Color.TRANSPARENT)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		button.add_theme_color_override("icon_" + state + "_color", Color.TRANSPARENT)
	button.add_theme_constant_override("outline_size", 0)


## A theme color as the mod expects it.
static func hex(color: Color) -> String:
	return "#" + color.to_html(true)
