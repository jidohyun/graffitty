extends RefCounted
## Explicit decorative-effect inventory shared by one-shot and scoped actions.
## Functional pane physics, layout constraints and navigation never belong here.
const NAMES := [
	"camera.zoom", "camera.tilt", "camera.drift", "camera.shake", "camera.dof",
	"sheet.curvature", "sheet.ripple", "sheet.splash", "sheet.gloss", "sheet.shadow",
	"lighting", "sparks", "cursor_trail", "pane_zoom", "tab_switch", "session_switch",
]
const GROUPS := {
	"camera": ["camera.zoom", "camera.tilt", "camera.drift", "camera.shake", "camera.dof"],
	"sheet": ["sheet.curvature", "sheet.ripple", "sheet.splash", "sheet.gloss", "sheet.shadow"],
	# Preserve the default timeout action: existing bursts/trails keep aging.
	"typing": ["camera.zoom", "camera.tilt", "camera.drift", "camera.shake", "camera.dof",
		"sheet.curvature", "sheet.ripple", "sheet.splash", "lighting", "pane_zoom"],
}


static func validate(selector: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for key in selector:
		if key not in ["include", "exclude"]:
			errors.append("Unknown effect selector key: " + str(key))
			continue
		var values = selector[key]
		if not values is Array:
			errors.append("Effect " + key + " must be an array of names")
			continue
		for value in values:
			if not value is String or (value != "all" and value not in NAMES and not GROUPS.has(value)):
				errors.append("Unknown effect: " + str(value))
	return errors


static func resolve(selector: Dictionary) -> Array:
	var included := _expand(selector.get("include", ["all"]))
	var excluded := _expand(selector.get("exclude", []))
	return included.filter(func(name): return name not in excluded)


static func _expand(names: Array) -> Array:
	var selected := []
	for name in names:
		var members: Array = NAMES if name == "all" else GROUPS.get(name, [name])
		for member in members:
			if member not in selected: selected.append(member)
	return selected
