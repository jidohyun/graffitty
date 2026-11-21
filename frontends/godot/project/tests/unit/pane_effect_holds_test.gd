extends "res://tests/unit/test_case.gd"
## Program-requested effect holds (OSC 4723) reach the focused pane's gates.
const Holds := preload("res://scenes/PaneEffectHolds.gd")
const Catalog := preload("res://graffitty/effects.gd")


class Recorder extends Node:
	var control := preload("res://scenes/EffectControl.gd").new()
	var disabled: Array = []
	func disable_effects(effects: Array) -> Callable:
		disabled.append(effects.duplicate())
		return control.hold(effects)


func test_holds_combine_off_and_on_across_records() -> void:
	expect(Holds.resolve([]) == [], "No holds select nothing")
	var one := Holds.resolve([{"id": "a", "off": ["sparks", "camera"]}])
	expect("sparks" in one and "camera.zoom" in one and "camera.dof" in one and "tab_switch" not in one,
		"Groups expand like config rule selectors")
	var combined := Holds.resolve([
		{"id": "a", "off": ["all"]},
		{"id": "b", "off": ["sparks"], "on": ["cursor_trail", "camera.zoom"]},
	])
	expect("cursor_trail" not in combined and "camera.zoom" not in combined, "on wins over off from another hold")
	expect("sparks" in combined and "tab_switch" in combined, "Everything else in all stays off")
	var unknown := Holds.resolve([{"id": "x", "off": ["glitter", "sparks"]}, "junk", {"id": 3}])
	expect(unknown == ["sparks"], "Unknown names and malformed records are ignored")


func test_focused_pane_holds_are_applied_once_and_released_on_change() -> void:
	var host := Recorder.new()
	var holds := Holds.new()
	holds.update(host, [{"id": "nvim", "off": ["sparks", "pane_zoom"], "until": "process"}])
	expect(host.disabled.size() == 1 and not host.control.allows("sparks") and host.control.allows("tab_switch"),
		"Holds gate exactly the named effects")
	holds.update(host, [{"id": "nvim", "off": ["sparks", "pane_zoom"], "until": "process"}])
	expect(host.disabled.size() == 1, "An unchanged selection is not re-applied")
	holds.update(host, [{"id": "nvim", "off": ["sparks"]}, {"id": "md", "off": ["camera"]}])
	expect(host.disabled.size() == 2 and host.control.allows("pane_zoom") and not host.control.allows("camera.tilt"),
		"A changed selection releases the previous gate and applies the new one")
	holds.update(host, [])
	expect(host.control.allows("sparks") and host.control.allows("camera.tilt"), "Focusing a pane without holds releases everything")
	holds.update(host, [{"id": "a", "off": ["tab_switch"]}])
	holds.clear()
	expect(host.control.allows("tab_switch") and holds.selected().is_empty(), "clear releases and forgets the selection")
	host.free()


func test_unknown_only_holds_leave_effects_alone() -> void:
	var host := Recorder.new()
	var holds := Holds.new()
	holds.update(host, [{"id": "future", "off": ["hologram"]}])
	expect(host.disabled.is_empty(), "Names this client does not know never gate anything")
	for name in Catalog.NAMES:
		expect(host.control.allows(name), "Effect stays allowed: " + name)
	host.free()
