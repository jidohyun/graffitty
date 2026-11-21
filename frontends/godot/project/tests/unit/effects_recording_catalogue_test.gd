extends "res://tests/unit/test_case.gd"
## The effects video recorder (videos/effects/recording) drives the real app.
## Its catalogue and neutral config must keep matching the app's effect
## options and the modes RecordEffects.gd handles, so an app change that would
## break a recording fails here instead of during a take.
const Effects := preload("res://scenes/Effects.gd")
const UserConfig := preload("res://config/UserConfig.gd")
const RECORDING := "../../../videos/effects/recording"
const CASE_KEYS := ["title", "category", "overrides", "setup_overrides", "demo", "transition", "plugin"]


func recording_path(file: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(RECORDING).path_join(file).simplify_path()


func catalogue() -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(recording_path("effects.json")))
	return parsed if parsed is Dictionary else {}


## The values RecordEffects.gd compares `settings.<field>` against.
func recorder_modes(field: String) -> Array[String]:
	var source := FileAccess.get_file_as_string(recording_path("RecordEffects.gd"))
	var pattern := RegEx.create_from_string(
		"settings(?:\\.get\\(\"%s\", \"\"\\)|\\.%s) == \"([a-z_]+)\"" % [field, field])
	var modes: Array[String] = []
	for found in pattern.search_all(source):
		if found.get_string(1) not in modes: modes.append(found.get_string(1))
	return modes


## The recorder's client config: neutral.toml alone, as it launches the app
## with an empty config home and --config=neutral.toml.
func neutral_args() -> PackedStringArray:
	return PackedStringArray(["--no-config", "--config=" + recording_path("neutral.toml")])


## A fresh effects config with the neutral base applied, as a recording starts.
func neutral() -> RefCounted:
	var effects = Effects.new()
	UserConfig.apply_effect_settings(effects, neutral_args())
	return effects


func test_neutral_config_is_a_valid_client_toml() -> void:
	var errors := UserConfig.validate_startup(neutral_args())
	expect(errors.is_empty(), "neutral.toml: %s" % [errors])
	var effects := neutral()
	expect(effects.warnings.is_empty(), "neutral.toml effects: %s" % [effects.warnings])


func test_every_override_is_a_valid_effect_option() -> void:
	var cases := catalogue()
	if not expect(not cases.is_empty(), "effects.json lists effects"): return
	for name in cases:
		var case: Dictionary = cases[name]
		var effects := neutral()
		var overrides: Array = case.get("setup_overrides", []) + case.get("overrides", [])
		expect(not case.get("overrides", []).is_empty(), "%s has overrides" % name)
		for override in overrides:
			# The same split and value parsing as TerminalWorld's --set=.
			var text := str(override)
			var at := text.find("=")
			var parts := text.substr(0, at).split(":")
			if not expect(at > 0 and parts.size() == 2, "%s: %s is section:key=value" % [name, text]): continue
			var raw := text.substr(at + 1)
			var value = str_to_var(raw)
			effects.set_option(parts[0], parts[1], value if value != null else raw)
		expect(effects.warnings.is_empty(), "%s: %s" % [name, effects.warnings])


func test_every_case_uses_a_mode_the_recorder_handles() -> void:
	var demos := recorder_modes("demo")
	var transitions := recorder_modes("transition")
	expect(demos.size() >= 3 and transitions.size() >= 2, "Found recorder modes: %s %s" % [demos, transitions])
	var cases := catalogue()
	for name in cases:
		var case: Dictionary = cases[name]
		for key in case:
			expect(key in CASE_KEYS, "%s: unknown field %s" % [name, key])
		expect(not str(case.get("title", "")).is_empty() and not str(case.get("category", "")).is_empty(),
			"%s has a title and category" % name)
		if case.has("demo"):
			expect(str(case.demo) in demos, "%s: RecordEffects.gd has no demo %s" % [name, case.demo])
		if case.has("transition"):
			expect(str(case.transition) in transitions, "%s: RecordEffects.gd has no transition %s" % [name, case.transition])
