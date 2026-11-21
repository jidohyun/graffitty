extends SceneTree
## Production startup applies server defaults and explicit launch arguments.
var failures: Array[String] = []
var dialog_seen := false
var checks: Array[Dictionary] = []

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	call_deferred("run")

func check(value: bool, message: String) -> void:
	print("[local startup] %s %s" % ["PASS" if value else "FAIL", message])
	checks.append({"status": "PASS" if value else "FAIL", "name": message})
	if not value: failures.append(message)

func retained_text(terminal: Node) -> String:
	# Capture contains physical row breaks, including wrapped long paths.
	return str(terminal.get_text(true).text).replace("\n", "")

func wait_for_host(wrapper: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline:
		dialog_seen = dialog_seen or wrapper.dialog.visible
		await process_frame
	dialog_seen = dialog_seen or wrapper.dialog.visible

func run() -> void:
	root.size = Vector2i(1280, 800)
	var deadline: int
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = OS.get_cmdline_user_args() + PackedStringArray(["--workspace=main"])
	root.add_child(wrapper)
	await wait_for_host(wrapper)
	check(wrapper.host != null, "local entry automatically creates a terminal on the owner")
	check(not dialog_seen, "local entry never asks for a URL, password or Connect click")
	if wrapper.host != null:
		var id: int = wrapper.host.active_session_id
		var term: Node = wrapper.host.sessions[id].term
		var pid: int = term.get_shell_pid()
		var session_name: String = wrapper.settings.workspace
		check(wrapper.host.sessions.size() == 1, "startup has exactly one pane")
		check(wrapper.host.menu_entry_specs().any(func(entry): return entry.label == "Sessions::Servers…"), "local desktop exposes Servers without user configuration")
		if DisplayServer.get_name() != "headless":
			await create_timer(0.5).timeout
			# An idle workspace deliberately stops drawing; read a forced frame.
			RenderingServer.force_draw(false)
			var shot := root.get_texture().get_image()
			var pixel := shot.get_pixel(int(shot.get_width() * 0.8), int(shot.get_height() * 0.8))
			# Pane glass is above the Flat world backdrop. Removing its tint
			# would leave only the world's .85 alpha and erase pane/gap contrast.
			var pane_over_world := 0.85 + 0.85 * (1.0 - 0.85)
			check(absf(pixel.a - pane_over_world) <= 1.0 / 255.0, "production pane renders configured 85 percent glass above the world backdrop")
		check(pid > 0, "new terminal has a server-owned shell")
		term.send_text("Write-Output ('AUTO_' + 'LOCAL_READY')\r" if OS.get_name() == "Windows" else "printf 'AUTO_%s_READY\\n' LOCAL\n")
		deadline = Time.get_ticks_msec() + 5000
		while "AUTO_LOCAL_READY" not in term.get_text(false).text and Time.get_ticks_msec() < deadline: await process_frame
		check("AUTO_LOCAL_READY" in term.get_text(false).text, "terminal accepts input immediately")
		term.send_text("Write-Output ('STARTUP_' + 'ACTUAL_CWD=' + (Get-Location).Path); Write-Output ('STARTUP_' + 'ACTUAL_ENV=' + $env:LOCAL_STARTUP_TEST_ENV)\r" if OS.get_name() == "Windows" else "printf 'STARTUP_%s_CWD=%s\\nSTARTUP_%s_ENV=%s\\n' ACTUAL \"$PWD\" ACTUAL \"$LOCAL_STARTUP_TEST_ENV\"\n")
		deadline = Time.get_ticks_msec() + 5000
		# Small windows can scroll the first output line off screen while printing
		# the second. CWD/environment assertions concern retained output.
		while "STARTUP_ACTUAL_ENV=configured-value" not in retained_text(term) and Time.get_ticks_msec() < deadline: await process_frame
		var text := retained_text(term)
		check("STARTUP_ACTUAL_CWD=" + OS.get_environment("GRAFFITTY_TEST_EXPECTED_CWD") in text, "recovered terminal uses this GUI's launch or configured cwd")
		check("STARTUP_ACTUAL_ENV=configured-value" in text, "recovered terminal applies configured environment")
		wrapper.connection.disconnect_remote()
		wrapper.queue_free()
		await process_frame
		wrapper = load("res://scenes/terminal.tscn").instantiate()
		wrapper.launch_args = PackedStringArray(["--no-plugin", "--workspace=" + session_name, "--attach-session"])
		root.add_child(wrapper)
		await wait_for_host(wrapper)
		check(wrapper.host != null, "entry automatically reattaches to the existing workspace")
		if wrapper.host != null:
			check(wrapper.host.sessions.size() == 1, "reattachment does not create a duplicate terminal")
			check(wrapper.host.active_session_id == id, "reattachment preserves terminal identity")
			check(wrapper.host.sessions[id].term.get_shell_pid() == pid, "reattachment preserves the shell")
		wrapper.connection.disconnect_remote()
		wrapper.queue_free()
		await process_frame
		var fresh_names: Array[String] = []
		for _launch in range(2):
			wrapper = load("res://scenes/terminal.tscn").instantiate()
			wrapper.launch_args = OS.get_cmdline_user_args() + PackedStringArray(["--new-session"])
			root.add_child(wrapper)
			await wait_for_host(wrapper)
			check(wrapper.host != null, "--new-session creates a fresh session")
			if wrapper.host != null:
				check(wrapper.settings.workspace != session_name and wrapper.settings.workspace not in fresh_names, "--new-session never resumes a retained session")
				fresh_names.append(wrapper.settings.workspace)
				check(wrapper.host.sessions.size() == 1 and wrapper.host.active_session_id != id, "fresh session starts with one new pane")
				var fresh_term: Node = wrapper.host.active_terminal()
				fresh_term.send_text("Write-Output ('FRESH_' + 'ACTUAL_CWD=' + (Get-Location).Path)\r" if OS.get_name() == "Windows" else "printf 'FRESH_%s_CWD=%s\\n' ACTUAL \"$PWD\"\n")
				deadline = Time.get_ticks_msec() + 5000
				var expected := "FRESH_ACTUAL_CWD=" + OS.get_environment("GRAFFITTY_TEST_EXPECTED_CWD")
				while expected not in retained_text(fresh_term) and Time.get_ticks_msec() < deadline: await process_frame
				check(expected in retained_text(fresh_term), "fresh session starts in the requested launch directory")
			wrapper.connection.disconnect_remote()
			wrapper.queue_free()
			await process_frame
		# The application's first window returns to the session shown last.
		wrapper = load("res://scenes/terminal.tscn").instantiate()
		root.add_child(wrapper)
		await wait_for_host(wrapper)
		check(wrapper.host != null, "ordinary launch opens a window")
		if wrapper.host != null:
			check(wrapper.connection.workspace == fresh_names[-1], "ordinary launch returns to the session shown last (%s, expected %s)" % [wrapper.connection.workspace, fresh_names[-1]])
			check(wrapper.host.sessions.size() == 1, "returning to a session starts no new pane")
		wrapper.connection.disconnect_remote()
		wrapper.queue_free()
		await process_frame
		wrapper = null
	check(not dialog_seen, "no connection form appeared in any launch")
	if is_instance_valid(wrapper): wrapper.connection.disconnect_remote()
	var report := {"failures": failures, "checks": checks, "dialog_seen": dialog_seen}
	var file := FileAccess.open(OS.get_environment("GRAFFITTY_TEST_REPORT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("LOCAL_STARTUP_PASS" if failures.is_empty() else "LOCAL_STARTUP_FAIL ", report)
	quit(0 if failures.is_empty() else 1)
