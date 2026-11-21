extends "res://tests/unit/test_case.gd"
const Settings := preload("res://graffitty/config.gd")
const Catalog := preload("res://graffitty/effects.gd")
const Context := preload("res://scenes/ContextRules.gd")
const Host := preload("res://scenes/TerminalHost.gd")
const World := preload("res://scenes/TerminalWorld.gd")
const View := preload("res://scenes/WorkspaceView.gd")
const Effects := preload("res://scenes/TerminalEffects.gd")


class Recorder extends Node:
	signal ui_changed
	var calls: Array = []
	func settle_effects(targets: Array) -> void:
		calls.append(targets.duplicate())


func test_explicit_rule_settles_once_per_foreground_identity_not_per_status_or_poll() -> void:
	var host := Recorder.new()
	var context := Context.new()
	context.rules = [Settings.Rule.on("app_changed", {}, Settings.Actions.settle({"include": ["typing"]}))]
	for app in ["nvim", "claude", "codex", "pi", "opencode"]:
		var state := {"id": app, "pid": 20, "started": "now"}
		var before := host.calls.size()
		context.update(host, "%1", state)
		expect(host.calls.size() == before + 1, "Explicit foreground rule settles once")
		for status in ["busy", "idle", "waiting", "offline"]:
			state.status = status
			context.update(host, "%1", state)
		expect(host.calls.size() == before + 1, "Status and identical polls never settle again")
		context.update(host, "%2", {"id": "bash", "pid": 2})
	context.update(host, "%1", {"id": "nvim", "pid": 20, "started": "now"})
	var before := host.calls.size()
	context.update(host, "%1", {"id": "nvim", "pid": 20, "started": "later"})
	expect(host.calls.size() == before + 1, "A fresh process with the same PID is a new app entry")
	context.update(host, "%1", {"id": "zsh", "pid": 10})
	context.update(host, "%1", {"id": "nvim", "pid": 20, "started": "later"})
	expect(host.calls.size() == before + 3, "Explicit unconditional rule also observes the intervening shell")
	host.free()


func test_agent_entry_does_not_implicitly_settle_effects() -> void:
	var host := Recorder.new()
	var context := Context.new()
	context.rules = preload("res://config/UserConfig.gd").context_rules(PackedStringArray())
	for app in ["nvim", "claude", "codex", "pi", "opencode", "zsh"]:
		for status in ["busy", "idle", "waiting"]:
			context.update(host, "%1", {"id": app, "pid": 20, "status": status})
	expect(host.calls.is_empty(), "Agent/editor entry and status updates leave typing effects alone")
	host.free()

func test_conditions_actions_and_focus_events_are_independent() -> void:
	var host := Recorder.new()
	var context := Context.new()
	context.rules = [
		Settings.Rule.on("app_changed", {"app": ["nvim"], "pane": "%2"},
			Settings.Actions.settle({"include": ["camera", "sheet", "lighting"]})),
		Settings.Rule.on("focus_changed", {"pane": "%3"},
			func(target): target.set_meta("focused", true)),
	]
	context.update(host, "%1", {"id": "nvim"})
	expect(host.calls.is_empty(), "All conditions must match")
	context.update(host, "%2", {"id": "nvim"})
	expect(host.calls == [Catalog.resolve({"include": ["camera", "sheet", "lighting"]})], "The action chooses its own effect targets")
	context.update(host, "%3", {})
	expect(host.get_meta("focused", false), "A different event can run an arbitrary host callback")
	context.rules.clear()
	context.update(host, "%2", {"id": "nvim"})
	expect(host.calls.size() == 1, "An empty rule list disables automatic actions")
	host.free()


func test_default_prefix_runs_the_same_one_shot_action() -> void:
	var host := Recorder.new()
	var prefix := preload("res://scenes/WorkspacePrefix.gd").new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	prefix.active = true
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_R
	key.unicode = 114
	expect(prefix.handle(key), "Default prefix R consumes the shortcut")
	expect(not prefix.active and host.calls == [Catalog.GROUPS.typing], "It invokes settle exactly once")
	key.echo = true
	prefix.handle(key)
	expect(host.calls.size() == 1, "Held shortcut repeat does not repeat cancellation")
	key = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_X
	expect(not prefix.handle(key), "Subsequent normal typing is not intercepted")
	host.free()


func test_settle_preserves_animation_then_new_typing_reactivates_immediately() -> void:
	var host := Host.new()
	var world := World.new()
	var view := View.new()
	var effects := Effects.new()
	host.world = world
	host.workspace_view = view
	view.host = host
	world.terminal_effects = effects
	world.fx_last_key = 12
	world.fx_typing = 0.8
	effects.last_key = 12
	effects.typing = 0.7
	view._pane_zoom.pulse("%1", 10)
	view._pane_zoom.advance(0.1, "%1", 0.3, 0.8)
	var previous: float = view._pane_zoom.weights["%1"]
	Settings.Actions.settle({"include": ["typing"]}).call(host)
	expect(world.fx_last_key < 0 and effects.last_key < 0, "Only activity triggers expire")
	expect(world.fx_typing == 0.8 and effects.typing == 0.7, "World animation weights do not jump")
	expect(view._pane_zoom.weights["%1"] == previous, "Pane zoom does not jump")
	view._pane_zoom.advance(0.01, "%1", 0.3, 0.8)
	var resting: float = view._pane_zoom.weights["%1"]
	expect(resting < previous and resting > 0, "The normal leave animation starts")
	view._pane_zoom.pulse("%1", 10)
	view._pane_zoom.advance(0.01, "%1", 0.3, 0.8)
	expect(view._pane_zoom.weights["%1"] > resting, "Typing immediately reverses the return animation")
	# Individual targets leave the other trigger alone.
	world.fx_last_key = 12
	Settings.Actions.settle({"include": ["pane_zoom"]}).call(host)
	expect(world.fx_last_key == 12, "Workspace-only action leaves world activity unchanged")
	view._pane_zoom.pulse("%1", 10)
	Settings.Actions.settle({"include": ["camera", "sheet", "lighting"]}).call(host)
	expect(view._pane_zoom.remaining == 10, "World-only action leaves pane zoom activity unchanged")
	effects.free()
	view.free()
	world.free()
	host.free()


func test_rules_are_validated_and_config_keeps_explicit_empty_override() -> void:
	const Loader := preload("res://config/UserConfig.gd")
	expect(Settings.validate_rules([]).is_empty(), "Empty rule set validates")
	expect(Settings.PrefixSettings.new().validate().is_empty(), "Default prefix bindings name registry actions")
	var invalid := Settings.Rule.on("app_changed", {"app": 12}, func(_host): pass)
	expect(not Settings.validate_rules([invalid]).is_empty(), "Invalid conditions are rejected")
	invalid = Settings.Rule.on("typo", {}, func(_host): pass)
	expect(not Settings.validate_rules([invalid]).is_empty(), "Unknown events are rejected")
	var empty := PackedStringArray([client_toml("no-rules", "rules = []\n")])
	expect(Loader.context_rules(empty).is_empty(), "Explicit empty rules remain empty")
	var configured := PackedStringArray([client_toml("rules", "[[rules]]\nevent = \"app_changed\"\napp = [\"vim\"]\naction = \"SettleEffects\"\ninclude = [\"pane_zoom\"]\n\n[[rules]]\nevent = \"active\"\napp = \"htop\"\naction = \"DisableEffects\"\n")])
	var rules: Array = Loader.context_rules(configured)
	expect(rules.size() == 2 and Settings.validate_rules(rules).is_empty(), "client.toml rules become validated Rule objects")
	expect(rules[0].event == "app_changed" and rules[0].conditions.app == ["vim"] and not rules[0].scoped, "Event rules keep their conditions")
	expect(rules[1].scoped and rules[1].conditions.app == "htop", "active rules are scoped")
	expect(Loader.context_rules(PackedStringArray()).is_empty(), "No implicit app-entry rules")
