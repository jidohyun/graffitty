extends "res://tests/unit/test_case.gd"
const Catalog := preload("res://graffitty/effects.gd")
const Actions := preload("res://graffitty/actions.gd")
const Rule := preload("res://graffitty/rule.gd")
const Context := preload("res://scenes/ContextRules.gd")
const EffectControl := preload("res://scenes/EffectControl.gd")
const Host := preload("res://scenes/TerminalHost.gd")


func test_selectors_expand_groups_and_exclusion_wins() -> void:
	expect(Catalog.resolve({}) == Catalog.NAMES, "Omitted include selects every effect")
	expect(Catalog.resolve({"include": ["all"]}) == Catalog.NAMES, "All is explicit too")
	var selected := Catalog.resolve({"include": ["all", "camera"], "exclude": ["camera", "sparks"]})
	expect(selected.size() == Catalog.NAMES.size() - 6, "Groups deduplicate before exclusion")
	expect("camera.zoom" not in selected and "sparks" not in selected, "Excluded names and groups win")
	expect(Catalog.resolve({"include": []}).is_empty(), "An empty include selects nothing")
	for invalid in [{"include": "camera"}, {"exclude": ["typo"]}, {"except": ["sparks"]}, {"include": [1]}]:
		expect(not Catalog.validate(invalid).is_empty(), "Invalid selectors fail validation")


func test_scoped_rules_follow_focus_combine_and_release_after_config_changes() -> void:
	var host := Host.new()
	var context := Context.new()
	context.rules = [
		Rule.while_active({"app": ["nvim", "codex"]}, Actions.disable({"exclude": ["sparks"]})),
		Rule.while_active({"pane": "%1"}, Actions.disable({"include": ["sparks"]})),
	]
	context.update(host, "%1", {"id": "nvim", "pid": 10})
	expect(Catalog.NAMES.all(func(name): return not host.effect_control.allows(name)), "Overlapping rules disable their union")
	host.effect_control.pulse()
	context.update(host, "%1", {"id": "nvim", "pid": 10, "status": "busy"})
	expect(not host.effect_control.allows("camera.zoom"), "Typing and status changes cannot release a hold")
	context.update(host, "%2", {"id": "codex", "pid": 20})
	expect(host.effect_control.allows("sparks") and not host.effect_control.allows("camera.zoom"), "Focus releases only the scope that no longer matches")
	context.rules.clear()
	context.update(host, "%2", {"id": "codex", "pid": 20})
	expect(Catalog.NAMES.all(func(name): return host.effect_control.allows(name)), "Removing rules releases even without a context change")
	host.free()


func test_once_and_scoped_actions_share_selection_and_animate() -> void:
	var host := Host.new()
	var selector := {"include": ["all"], "exclude": ["sparks"]}
	Actions.settle(selector).call(host)
	expect(host.effect_control.weight("tab_switch") == 1.0, "Settle never changes the displayed frame immediately")
	host.effect_control.advance(.01, .5, 1.5)
	expect(host.effect_control.weight("tab_switch") < 1.0 and host.effect_control.weight("tab_switch") > 0.0, "Included effects fade smoothly")
	expect(host.effect_control.weight("sparks") == 1.0, "Excluded effects keep their weight")
	host.effect_control.pulse()
	expect(host.effect_control.allows("tab_switch"), "One-shot selection releases on the next key")
	var first: Callable = Actions.disable(selector).call(host)
	var second: Callable = Actions.disable({"include": ["tab_switch"]}).call(host)
	host.effect_control.pulse()
	expect(not host.effect_control.allows("tab_switch") and host.effect_control.allows("sparks"), "Same selector stays off in a scoped action")
	first.call()
	expect(host.effect_control.allows("camera.zoom") and not host.effect_control.allows("tab_switch"), "Releasing one owner preserves the other")
	second.call()
	expect(host.effect_control.allows("tab_switch"), "Last release restores configured effects")
	first.call()
	expect(host.effect_control.allows("tab_switch"), "Release is idempotent")
	host.free()


func test_partial_camera_selection_and_named_rest_state_are_preserved() -> void:
	var control := EffectControl.new()
	var source := {"camera.zoom": 2.0, "camera.drift_px": 20.0, "sheet.ripple": 2.0}
	var rest := {"camera.zoom": 1.2, "camera.drift_px": 3.0, "sheet.ripple": .1}
	control.settle(["camera.zoom"])
	var destination := control.frame(source, true, rest)
	expect(destination["camera.zoom"] == 1.2, "One-shot targets the authored rest zoom")
	expect(destination["camera.drift_px"] == 20.0 and destination["sheet.ripple"] == 2.0, "Unselected effects keep the active frame")
	var release := control.hold(["camera.zoom"])
	expect(control.frame(source, true, rest)["camera.zoom"] == 1.0, "Persistent disable removes even resting zoom")
	expect(source["camera.zoom"] == 2.0 and rest["camera.zoom"] == 1.2, "Neither action mutates the preset")
	release.call()


func test_all_keeps_functional_pane_physics_and_typing_pin() -> void:
	var host := Host.new()
	var view := preload("res://scenes/WorkspaceView.gd").new()
	host.workspace_view = view
	view.host = host
	view.physics_typing = true
	view._typing_tab = 3
	view._pane_zoom.pulse("%1", 10)
	Actions.settle().call(host)
	expect(view._pane_zoom.remaining == 0.0, "All settles decorative pane zoom")
	expect(view.physics_typing and view._typing_tab == 3, "All preserves the functional typing pin and physics activity")
	var release: Callable = Actions.disable().call(host)
	expect(view.physics_typing, "Persistent all also leaves pane physics alone")
	release.call()
	view.free()
	host.free()


func test_gated_trails_finish_without_restarting_during_output() -> void:
	for path in ["res://scenes/CursorTrail.gd", "res://scenes/CursorTrail2D.gd"]:
		for style in ["smear", "blaze", "lightning"]:
			var trail = load(path).new()
			trail._ready()
			trail.configure(1, Vector2(.1, .4), Vector2.ZERO, Color.WHITE, style, {"duration": .2})
			var project: Callable = func(uv): return Transform3D(Basis(), Vector3(uv.x, uv.y, 0))
			if trail is Node2D: project = func(uv): return uv * Vector2(800, 400)
			for cell in [Vector2i(1, 1), Vector2i(20, 5), Vector2i(20, 5)]:
				trail.update_cursor(cell, Vector2i(80, 24), .01, Vector2(10, 20), project)
			expect(trail.active, "Trail starts before disabling")
			for i in 100:
				trail.update_cursor(Vector2i(i % 80, i % 24), Vector2i(80, 24), .02, Vector2(10, 20), project, Rect2(0, 0, 1, 1), Color.WHITE, false)
			expect(not trail.active, "Suppressed trail ages out despite continuous terminal output: " + style)
			trail.free()
