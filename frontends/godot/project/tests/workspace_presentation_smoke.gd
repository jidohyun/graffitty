extends "res://tests/workspace_render_updates_smoke.gd"
## Run with --flat-2d on Android's renderer and without it for desktop Flat.
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")

func chromium_checks() -> void:
	var first: int = host.workspace_layout.active
	for i in 3:
		var previous: int = host.workspace_layout.active
		host.create_session()
		var deadline := Time.get_ticks_msec() + 5000
		while host.workspace_layout.active == previous and Time.get_ticks_msec() < deadline:
			await process_frame
		check(host.workspace_layout.active != previous, "Creating a tab selects its presentation")
		await wait(0.4)
		host.active_terminal().configure_advanced({"cursor_blink": 0})
	# Include rapid interrupted transitions, then return to the original scene.
	for i in 3:
		for tab in host.workspace_layout.tabs:
			host.select_workspace(int(tab.id))
			await wait(0.05)
	host.select_workspace(first)
	await wait(2.5)
	var active := 0
	for id in host.sessions:
		var pair: Dictionary = host.sessions[id]
		if Updates.is_active(pair.vp):
			active += 1
		else:
			check(not pair.term.is_processing() and pair.vp.size == Vector2i(2, 2), "Inactive tab has no frame processing or retained render target")
	check(active == 1, "Only the selected tab prepares pixels after repeated switching")
	for pane in host.workspace_view.panes.values():
		check(pane.can_process() == pane.visible, "Only visible pane headers and controls process frames")
	check("ON_DEMAND_VISIBLE" in str(host.active_terminal().get_text(false).get("text", "")), "Reattached terminal restores the owner's scene")
	if host.world.get("_transition_stale") != null:
		check(host.world._transition_stale.is_empty(), "Interrupted 2D transitions retire every stale capture")
	await inactive_output_checks(first)
	var before := draws
	await wait(1.0)
	check(draws - before <= 2, "Repeated tab effects return to idle: %d frames" % (draws - before))
	host.layout_root.hide()
	await wait(0.2)
	check(not host.presentation_active and host.sessions.values().all(func(pair): return not pair.term.is_processing()), "Hiding a session stops all of its terminal processing")
	check(host.session_backend.connection.subscriptions.is_empty(), "Hidden session unsubscribes from presentation streams")
	host.layout_root.show()
	await wait(0.6)
	check(host.presentation_active and host.active_terminal().is_processing(), "Showing a session resumes the selected terminal")
	check("ON_DEMAND_VISIBLE" in str(host.active_terminal().get_text(false).get("text", "")), "Session resume restores terminal contents")


func inactive_output_checks(first: int) -> void:
	var connection: Node = host.session_backend.connection
	var selected: int = host.active_session_id
	var hidden: Array = host.sessions.keys().filter(func(id): return id != selected)
	check(connection.subscriptions == [selected], "Only the selected tab subscribes to terminal scenes")
	var samples := {"scenes": 0, "repaints": 0}
	var received := func(id, _header, _data):
		if id in hidden: samples.scenes += 1
	var repainted := func(): samples.repaints += 1
	connection.terminal_received.connect(received)
	for id in hidden: host.sessions[id].term.frame_changed.connect(repainted)
	var before := draws
	for i in 20:
		for id in hidden:
			connection.send_input(id, ("HIDDEN_OUTPUT_%d_%d\n" % [id, i]).to_utf8_buffer())
		await wait(0.02)
	await wait(0.4)
	check(samples.scenes == 0 and samples.repaints == 0, "Busy hidden tabs produce zero client scene updates and native repaints: %s" % samples)
	check(draws - before <= 2, "Hidden terminal output leaves the visible workspace idle: %d frames" % (draws - before))
	for id in hidden:
		var pair: Dictionary = host.sessions[id]
		check(not pair.term.is_processing() and not pair.term.is_render_active() and pair.vp.render_target_update_mode == SubViewport.UPDATE_DISABLED and pair.vp.size == Vector2i(2, 2), "Busy hidden tab keeps processing and rendering disabled")
		check(not "HIDDEN_OUTPUT_" in str(pair.term.get_text(false).get("text", "")), "Hidden replica does not consume the owner's new terminal contents")
		pair.term.frame_changed.disconnect(repainted)
	connection.terminal_received.disconnect(received)
	var capture_budget := preload("res://scenes/EffectCaptureBudget.gd")
	check(capture_budget._targets.all(func(reference): return not is_instance_valid(reference.get_ref()) or reference.get_ref().is_queued_for_deletion()), "Completed transitions retain no capture targets")
	var target: int = hidden[0]
	host.select_workspace(host.workspace_layout.containing("%%%d" % target))
	await wait(2.5)
	check(connection.subscriptions == [target] and ("HIDDEN_OUTPUT_%d_19" % target) in str(host.active_terminal().get_text(false).get("text", "")), "Selecting a previously busy hidden tab restores the latest owner snapshot")
	host.select_workspace(first)
	await wait(2.5)
