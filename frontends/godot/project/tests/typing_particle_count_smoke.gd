extends SceneTree
## Count actual particles from native key/IME events, including overlapping bursts.
var failures := 0
var effects: Array[Node] = []

class Ime extends "res://scenes/input/AndroidTerminalIme.gd":
	func _terminal() -> Control: return terminal_owner

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-particle-count-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func counts() -> Array:
	return effects.map(func(effect): return effect.particles.sparks.size())

func added(before: Array, expected: int, label: String) -> void:
	for i in effects.size():
		var count: int = effects[i].particles.sparks.size() - int(before[i])
		check(count == expected, "%s: %s adds %d particles (expected %d)" % [label, effects[i].get_script().resource_path.get_file(), count, expected])

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 400)
	root.add_child(viewport)
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.use_custom_key_bindings = true
	terminal.size = Vector2(640, 400)
	viewport.add_child(terminal)
	terminal.grab_focus()
	await process_frame
	terminal.remote_feed_stream("prompt> ".to_utf8_buffer(), 80, 24, true, false)
	await process_frame
	for script in [preload("res://scenes/TerminalEffects.gd"), preload("res://scenes/TerminalEffects2D.gd")]:
		var effect: Node = script.new()
		root.add_child(effect)
		effect.config.set_option("state.typing", "typing.particles", "sparks")
		var mapping: Callable = (func(uv): return Transform3D(Basis.IDENTITY, Vector3(uv.x, uv.y, 0))) if effect is Node3D else (func(uv): return uv * Vector2(640, 400))
		effect.bind_terminal(terminal, null, mapping, func(point): return mapping.call(point / Vector2(640, 400)))
		# Freeze aging, so each increment counts newly emitted particles exactly.
		effect.process_mode = Node.PROCESS_MODE_DISABLED
		effects.append(effect)
	for desktop in [false, true]:
		for stroke in 10:
			var before := counts()
			var key := InputEventKey.new()
			key.keycode = KEY_A
			key.unicode = 97
			key.pressed = true
			key.echo = stroke > 0
			if desktop: viewport.push_input(key)
			else: terminal.send_key(key)
			key.pressed = false
			if desktop: viewport.push_input(key)
			else: terminal.send_key(key)
			await process_frame
			await process_frame
			added(before, 6, ("Desktop" if desktop else "Accessory") + " key %d" % stroke)
	var ime := Ime.new()
	ime.terminal_owner = terminal
	ime.opened = true
	for preview in ["ㅎ", "하", "한"]:
		var before := counts()
		ime._native_event(0, "", preview, 0, 0, 0)
		await process_frame
		await process_frame
		added(before, 6, "Android composition " + preview)
	var before := counts()
	ime._native_event(0, "", "한", 0, 0, 0)
	await process_frame
	await process_frame
	added(before, 0, "Duplicate Android composition callback")
	ime.free()
	for effect in effects: effect.free()
	terminal.free()
	viewport.free()
	print("TYPING_PARTICLE_COUNT_PASS" if failures == 0 else "TYPING_PARTICLE_COUNT_FAIL")
	quit.call_deferred(failures)
