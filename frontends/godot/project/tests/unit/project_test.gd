extends "res://tests/unit/test_case.gd"
## Whole-project rules: everything compiles and every shipped preset loads.


func scripts_under(directory: String) -> Array[String]:
	var found: Array[String] = []
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			found.append(directory.path_join(file))
	for sub in DirAccess.get_directories_at(directory):
		found.append_array(scripts_under(directory.path_join(sub)))
	return found


func test_every_script_compiles() -> void:
	for directory in ["res://scenes", "res://graffitty", "res://config"]:
		for path in scripts_under(directory):
			var script: Script = load(path)
			expect(script != null and script.can_instantiate(), "%s does not compile" % path)


func test_every_preset_loads_without_warnings() -> void:
	for file in DirAccess.get_files_at("res://presets"):
		if not file.ends_with(".conf"):
			continue
		var effects: RefCounted = load("res://scenes/Effects.gd").new()
		expect(effects.load_config("res://presets/" + file), "%s does not load" % file)
		expect(effects.warnings.is_empty(), "%s: %s" % [file, effects.warnings])


func test_typing_eases_every_setting_without_a_jump() -> void:
	# Between rest and typing every number moves one way, never past either end.
	var effects: RefCounted = load("res://scenes/Effects.gd").new()
	effects.load_config("res://presets/flat.conf")
	var rest: Dictionary = effects.frame(String(effects.behavior.rest_state))
	var typing: Dictionary = effects.frame(String(effects.behavior.active_state))
	var previous: Dictionary = rest
	for step in range(1, 101):
		var frame: Dictionary = effects.blend(rest, typing, step / 100.0)
		for key in frame:
			if not (frame[key] is float or frame[key] is int):
				continue
			var low := minf(rest[key], typing[key])
			var high := maxf(rest[key], typing[key])
			expect(
				frame[key] >= low - 1e-6 and frame[key] <= high + 1e-6,
				"%s leaves [%s, %s] at %d%%" % [key, low, high, step],
			)
			expect(
				(frame[key] - previous[key]) * (typing[key] - rest[key]) >= -1e-9,
				"%s turns back at %d%%" % [key, step],
			)
		previous = frame
