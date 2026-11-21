extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/tab-move-world-place.md


func play() -> void:
	await open_tabs(5)
	if not await open_bistro():
		return
	var world: Node = host.world
	await say("Select the second tab")
	await select_tab(1)
	await wait_landed()
	var moved: int = int(host.get_tabs()[1].id)
	var shell: int = host.sessions[moved].term.get_shell_pid()
	var session_place: Transform3D = world.surfaces[world.active].global_transform
	var session_camera: Transform3D = world.cam.global_transform
	check(
		world.surfaces[world.active].global_transform.is_equal_approx(session_place),
		"The second tab uses the session’s current place",
	)

	await say("Drag the second tab to the fourth position and watch")
	await drag(tab_grip(1), on(tab_button(3), Vector2(0.9, 0.5)), 1.6)
	var frames := await watch_camera(4.0)
	check(int(host.get_tabs()[3].id) == moved, "The tab bar shows it fourth")
	check(
		world.surfaces[world.active].global_transform.is_equal_approx(session_place)
		and int(world.surfaces[world.active].session_id) == moved,
		"The reordered tab keeps the session’s place",
	)
	check_no_jump_cut(frames, "Reordering within the session")
	check(world.cam.global_transform.is_equal_approx(session_camera), "Reordering does not move the settled camera")
	check(host.sessions[moved].term.get_shell_pid() == shell, "The reordered tab keeps the same shell")

	await say("Select the second tab at the same session place")
	await select_tab(1)
	await wait_landed()
	check(
		world.surfaces[world.active].global_transform.is_equal_approx(session_place),
		"The second tab uses the same session place",
	)
	await say("Select the moved tab again")
	await select_tab(3)
	await wait_landed()
	check(
		world.surfaces[world.active].global_transform.is_equal_approx(session_place),
		"The moved tab returns to the same session place",
	)
