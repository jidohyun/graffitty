extends "../../../../tests/llm-e2e/replay/replay.gd"
## Real-frontend foreground-app rules, launched by tests/server/test_foreground_apps.py
## against a private server. Prints FOREGROUND_EFFECTS_REPLAY_PASS.
const Flat2D := preload("res://scenes/Flat2DWorld.gd")
const Rule := preload("res://graffitty/rule.gd")
const Actions := preload("res://graffitty/actions.gd")


static func record_settle(target) -> void:
	target.set_meta("app_settles", int(target.get_meta("app_settles", 0)) + 1)
	target.set_meta("settled_at_rest", not target.effect_control.allows("camera.zoom"))
	target.set_meta("settled_weight", target.world.fx_typing)


func play() -> void:
	var tree: SceneTree = self
	# No app rule is on by default: this is the one from the customization guide,
	# followed by a probe that records what it left.
	host.context_rules.rules.append(Rule.on("app_changed", {"app": "nvim"}, Actions.settle({"include": ["typing"]})))
	host.context_rules.rules.append(Rule.on("app_changed", {"app": "nvim"}, record_settle))
	await tree.create_timer(0.5).timeout
	var id: int = host.active_session_id
	var connection: Node = host.session_backend.connection
	var terminal: Node = host.sessions[id].term
	var command := OS.get_environment("GRAFFITTY_TEST_APP_COMMAND")
	for world_path in ["", "flat-2d"]:
		if not check(host.switch_world(world_path), "World loads"): return
		await tree.create_timer(0.2).timeout
		# Headless windows may skip Control layout; bind the same signals as refresh().
		host.workspace_view._bind_projection_world()
		var world: Node = host.world
		var before: int = host.get_meta("app_settles", 0)
		world.set_process(false)
		world.fx_typing = 0.7
		world.fx_last_key = world.fx_time + 30
		connection.send_action("text", id, {"text": command + "\n"})
		var deadline := Time.get_ticks_msec() + 10000
		while int(host.get_meta("app_settles", 0)) == before and Time.get_ticks_msec() < deadline:
			await tree.create_timer(0.02).timeout
		if not check(int(host.get_meta("app_settles", 0)) == before + 1, "Foreground event reaches rule exactly once"): return
		if not check(bool(host.get_meta("settled_at_rest")), "The settle rule puts typing effects at rest"): return
		if not check(is_equal_approx(float(host.get_meta("settled_weight")), 0.7), "Event preserves displayed weight"): return
		terminal.keystroke.emit(Vector2i(0, 0), 120)
		if not check(world.fx_last_key >= 0 and host.effect_control.allows("camera.zoom"), "Real terminal keystroke reactivates world effect"): return
		await tree.create_timer(1.0).timeout
		if not check(int(host.get_meta("app_settles", 0)) == before + 1 and host.effect_control.allows("camera.zoom"), "Repeated foreground polls never settle new typing"): return
		if not exercise_selectors(terminal): return
		world.set_process(true)
		deadline = Time.get_ticks_msec() + 10000
		while host.sessions[id].model.foreground_app.get("id", "") == "nvim" and Time.get_ticks_msec() < deadline:
			await tree.create_timer(0.02).timeout
		if not check(host.sessions[id].model.foreground_app.get("id", "") != "nvim", "Exiting app publishes shell context"): return
		print("FOREGROUND_EFFECTS_WORLD_PASS ", world_path)
	var release: Callable = Actions.disable().call(host)
	if not check(host.switch_world(""), "World switches under an all-effects hold"): return
	if not check(not host.world.effect_control.allows("sparks"), "New world inherits the host's hold"): return
	release.call()
	if not check(host.world.effect_control.allows("sparks"), "Release reaches the new world"): return


func exercise_selectors(terminal) -> bool:
	var world: Node = host.world
	var effects_overlay: Node = world.effects_2d if world is Flat2D else world.terminal_effects
	var scoped = Rule.while_active({"app": "nvim"}, Actions.disable({"exclude": ["sparks"]}))
	host.context_rules.rules.append(scoped)
	host.refresh_app_context()
	var bursts: int = effects_overlay.burst_count
	var rings: int = effects_overlay.splash_rings.size()
	var prior_weight: float = host.effect_control.weight("tab_switch")
	terminal.keystroke.emit(Vector2i(0, 0), 120)
	if not check(effects_overlay.burst_count > bursts, "Excluded sparks still emit while the app rule holds"): return false
	if not check(effects_overlay.splash_rings.size() == rings, "Held splashes do not emit"): return false
	if not check(host.effect_control.weight("tab_switch") == prior_weight, "Holding effects does not jump the displayed weight"): return false
	# Advance the real renderer under repeated typing, including its camera and shader.
	for i in 60:
		if i % 10 == 0: terminal.keystroke.emit(Vector2i(0, 0), 120)
		if world is Flat2D: world._process(.05)
		else: world._fx_step(.05)
	if not check(is_equal_approx(world.fx_camera.target_zoom, 1.0), "Held camera stays neutral despite typing"): return false
	if not check(float(world.fx_mat.get_shader_parameter("ripple")) < .001, "Held ripple fades out in the actual sheet shader"): return false
	if not check(host.workspace_view._pane_zoom.remaining <= 0.0, "Held pane zoom stays idle"): return false
	if not check(host.workspace_view.physics_typing, "Functional pane physics typing pin stays active"): return false
	var off: Callable = Actions.disable().call(host)
	bursts = effects_overlay.burst_count
	terminal.keystroke.emit(Vector2i(0, 0), 120)
	if not check(effects_overlay.burst_count == bursts, "All-effects hold also stops sparks"): return false
	host.context_rules.rules.erase(scoped)
	host.refresh_app_context()
	if not check(not host.effect_control.allows("sparks"), "Removing an app rule preserves another hold"): return false
	off.call()
	terminal.keystroke.emit(Vector2i(0, 0), 120)
	if not check(effects_overlay.burst_count > bursts, "Releasing the last hold restores particle bursts"): return false
	Actions.settle({"exclude": ["sparks"]}).call(host)
	if not check(host.effect_control.allows("sparks") and not host.effect_control.allows("camera.zoom"), "One-shot uses identical exclusion semantics"): return false
	terminal.keystroke.emit(Vector2i(0, 0), 120)
	if not check(host.effect_control.allows("camera.zoom"), "Next key releases the one-shot selection"): return false
	return true


