extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/tab-new-window.md
## New windows open inside this recording: a replay hosts the app's windows.


func owner_of(title: String) -> Node:
	for window_host in app.hosts:
		for id in window_host.sessions:
			var model: Node = window_host.session_model(id)
			if model != null and model.title == title:
				return window_host
	return null


func pid_in(window_host: Node, title: String) -> int:
	for id in window_host.sessions:
		var model: Node = window_host.session_model(id)
		if model != null and model.title == title:
			return window_host.sessions[id].term.get_shell_pid()
	return -1


func play() -> void:
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE"])
	await say("Drag BRAVO's tab straight down into its own content and release")
	await drag(tab_grip(1), content(Vector2(0.5, 0.55)), 1.4)
	var deadline := Time.get_ticks_msec() + 15000
	while (owner_of("BRAVO") == host or app.hosts.size() < 2) and Time.get_ticks_msec() < deadline:
		await process_frame
	var bravo := owner_of("BRAVO")
	check(
		bravo != null and bravo != host and app.hosts.size() == 2,
		"A new window opens holding BRAVO",
	)
	check(bravo != null and pid_in(bravo, "BRAVO") == shells["BRAVO"], "It is BRAVO's same shell")
	if bravo != null:
		var name: String = bravo.session_backend.connection.workspace
		# Sessions are addressed by their stable numbered identity, such as $1.
		check(name.begins_with("$") and name.substr(1).is_valid_int() and name != host.session_backend.connection.workspace,
			"BRAVO's new window owns a distinct numbered server session")
	check(
		titles() == ["ALPHA", "CHARLIE"],
		"The first window keeps ALPHA and CHARLIE (%s)" % [titles()],
	)

	await say("Drag CHARLIE's tab out past the window's edge and release")
	# A detached native window can extend beyond the original window's right
	# edge. Choose a desktop point beyond every host, then map it to this viewport.
	var right_edge := 0.0
	for window_host in app.hosts:
		var window: Window = window_host.get_window()
		right_edge = maxf(right_edge, float(window.position.x + window.size.x))
	var desktop_point := Vector2(right_edge + 160.0, float(root.position.y) + 200.0)
	var outside: Vector2 = root.get_screen_transform().affine_inverse() * (desktop_point - Vector2(root.position))
	check(app._window_at(desktop_point) == null, "The drop point is outside every native window")
	await drag(tab_grip(1), outside, 1.4)
	deadline = Time.get_ticks_msec() + 15000
	while (owner_of("CHARLIE") == host or app.hosts.size() < 3) and Time.get_ticks_msec() < deadline:
		await process_frame
	var charlie := owner_of("CHARLIE")
	check(
		charlie != null and charlie != host and charlie != bravo and app.hosts.size() == 3,
		"Outside every window, CHARLIE becomes a third window",
	)
	check(
		charlie != null and pid_in(charlie, "CHARLIE") == shells["CHARLIE"],
		"It is CHARLIE's same shell",
	)
	check(titles() == ["ALPHA"], "The first window keeps only ALPHA (%s)" % [titles()])
	if charlie != null and bravo != null:
		var name: String = charlie.session_backend.connection.workspace
		# Sessions are addressed by their stable numbered identity, such as $1.
		check(name.begins_with("$") and name.substr(1).is_valid_int() and name not in [host.session_backend.connection.workspace, bravo.session_backend.connection.workspace],
			"CHARLIE's new window owns a third numbered server session")
