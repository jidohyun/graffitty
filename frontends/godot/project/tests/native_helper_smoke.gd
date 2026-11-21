extends SceneTree
## Run through Graffitty.app too: its name differs from the helper only by case.
func _initialize() -> void:
	call_deferred("run")

static func exchange(pipe: FileAccess) -> Dictionary:
	pipe.store_line('{"title":""}')
	pipe.flush()
	var response = JSON.parse_string(pipe.get_line())
	return response if response is Dictionary else {}

func run() -> void:
	var binary := preload("res://graffitty/executables.gd").cli()
	var process := OS.execute_with_pipe(binary, ["--desktop-notification"])
	var thread := Thread.new()
	# Validation happens before any native notification is displayed.
	thread.start(exchange.bind(process.stdio))
	var deadline := Time.get_ticks_msec() + 10000
	while thread.is_alive() and Time.get_ticks_msec() < deadline:
		await process_frame
	if thread.is_alive(): OS.kill(process.pid)
	var response: Dictionary = thread.wait_to_finish()
	var passed: bool = response.get("error") == "Notification title is empty"
	print("NATIVE_HELPER_PASS" if passed else "NATIVE_HELPER_FAIL", " ", binary, " ", response)
	thread = null
	process.clear()
	await process_frame
	quit(0 if passed else 1)
