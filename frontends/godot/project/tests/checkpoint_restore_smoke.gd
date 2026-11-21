extends SceneTree
## Run headless with -- --restore-checkpoint=/path/to/fixture.json.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var app: Node = root.get_node("TerminalApplication")
	var parent: Node = await prepare_restore()
	var previous_hosts: Array = app.hosts.duplicate()
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	parent.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 30000
	while (wrapper.host == null or root.get_node("TerminalApplication").checkpoints.importing) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(.3).timeout
	var expected = JSON.parse_string(
		FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0].trim_prefix("--restore-checkpoint="))
	)
	# Restored chromiums load their pages after the import completes.
	deadline = Time.get_ticks_msec() + 30000
	while not await chromium_pages_restored(app, expected) and Time.get_ticks_msec() < deadline:
		await create_timer(.25).timeout
	var response: Dictionary = await app.checkpoints.capture()
	var ok: bool = response.has("result") and app.hosts.size() == expected.windows.size() + previous_hosts.size()
	if ok:
		for i in expected.windows.size():
			var actual: Dictionary = JSON.parse_string(JSON.stringify(response.result.windows[i + previous_hosts.size()]))
			var saved: Dictionary = expected.windows[i]
			var restore: Node = app.checkpoints
			ok = ok and int(actual.active) == int(restore.restored_tabs[int(saved.active)])
			ok = ok and actual.tabs.size() == saved.tabs.size()
			for index in mini(actual.tabs.size(), saved.tabs.size()):
				var wanted: Dictionary = preload("res://scenes/session/ServerWorkspace.gd").map_value(restore.decode(saved.tabs[index]), func(id): return restore.restored_ids[int(id)])
				wanted.id = restore.restored_tabs[int(saved.tabs[index].id)]
				var found: Dictionary = restore.decode(actual.tabs[index])
				ok = ok and int(found.id) == int(wanted.id)
				ok = ok and tab_matches(found, wanted)
				if wanted.has("navigation"):
					ok = ok and found.get("navigation", {}) == wanted.navigation
			ok = ok and actual.panes.size() == saved.panes.size()
			for pane in actual.panes:
				ok = ok and int(pane.pid) > 0
			for pane in saved.panes:
				var found_panes: Array = actual.panes.filter(func(p): return int(p.id) == int(restore.restored_ids[int(pane.id)]))
				ok = ok and found_panes.size() == 1
				if found_panes.size() == 1:
					ok = ok and str(found_panes[0].title) == str(pane.title)
					if pane.has("font_size"): ok = ok and int(found_panes[0].font_size) == int(pane.font_size)
				if pane.has("filetree"):
					var found: Array = actual.panes.filter(func(p): return int(p.id) == int(restore.restored_ids[int(pane.id)]))
					ok = ok and found.size() == 1 and found[0].get("filetree") is Dictionary
					if found.size() == 1 and found[0].get("filetree") is Dictionary:
						ok = ok and int(found[0].filetree.owner) == int(restore.restored_ids[int(pane.filetree.owner)])
						ok = ok and found[0].filetree.root == pane.filetree.root
			ok = ok and actual.chromiums.size() == saved.chromiums.size()
			for chromium in saved.chromiums:
				var found: Array = actual.chromiums.filter(func(c): return int(c.id) == int(restore.restored_ids[int(chromium.id)]))
				ok = ok and found.size() == 1
				if found.size() == 1:
					ok = ok and found[0].urls == chromium.urls and str(found[0].title) == str(chromium.title)
					for field in ["profile", "profile_template"]:
						ok = ok and found[0].get(field) == chromium.get(field)
					# Without a saved owner, its window's first terminal opens it.
					var terminals: Array = saved.panes.filter(func(pane): return not pane.has("filetree"))
					var owner: int = int(restore.restored_ids[int(chromium.owner if chromium.owner != null else terminals[0].id)])
					ok = ok and int(found[0].owner) == owner
			if saved.has("graph"):
				var wanted: Dictionary = preload("res://scenes/session/ServerWorkspace.gd").map_value(saved.graph, func(id): return restore.restored_ids[int(id)])
				ok = ok and int(actual.graph.run_messages) == int(wanted.run_messages)
				ok = ok and actual.graph.edges.size() == wanted.edges.size()
				for edge in wanted.edges:
					var matches: Array = actual.graph.edges.filter(func(e): return e.from == edge.from and e.to == edge.to)
					ok = ok and matches.size() == 1
					if matches.size() == 1:
						for field in edge: ok = ok and matches[0].get(field) == edge[field]
	if ok:
		ok = await observe_restore(app, response.result) and ok
	ok = await save_restored_checkpoint(app, expected) and ok
	print("CHECKPOINT RESTORE SMOKE: ", "PASS" if ok else JSON.stringify(response))
	quit(0 if ok else 1)


func save_restored_checkpoint(app: Node, expected: Dictionary) -> bool:
	# Exercise the real capability socket while allowing the engine to serve it.
	var context: Dictionary = app.agent_api.environment_for(int(app.checkpoints.restored_ids[int(expected.windows[0].panes[0].id)]))
	OS.set_environment("GRAFFITTY_SOCKET", str(context.GRAFFITTY_SOCKET))
	OS.set_environment("GRAFFITTY_TOKEN", str(context.GRAFFITTY_TOKEN))
	var outcome := await execute_cli(["checkpoint", "save", "--tag", "runtime"])
	if outcome.code != 0:
		print("CAPTURE FAILED: ", outcome.output)
		return false
	return await observe_save(app)


func execute_cli(args: PackedStringArray) -> Dictionary:
	var outcome := { "code": -1, "output": [], "done": false }
	var finish := func(): outcome.done = true
	var worker := Thread.new()
	worker.start(
		func():
			var result: Dictionary = preload("res://graffitty/executables.gd").run_cli(args)
			outcome.code = result.code
			outcome.output = [result.output, result.errors]
			finish.call_deferred(),
	)
	while not outcome.done:
		await process_frame
	worker.wait_to_finish()
	return outcome


func chromium_pages_restored(app: Node, expected: Dictionary) -> bool:
	var response: Dictionary = await app.checkpoints.capture()
	if not response.has("result"):
		return false
	var pages := {}
	for window in response.result.windows:
		for chromium in window.chromiums:
			pages[int(chromium.id)] = chromium.urls
	for window in expected.windows:
		for chromium in window.chromiums:
			if pages.get(int(app.checkpoints.restored_ids.get(int(chromium.id), -1))) != chromium.urls:
				return false
	return true


func observe_restore(_app: Node, _snapshot: Dictionary) -> bool:
	return true


func prepare_restore() -> Node:
	return root


func observe_save(_app: Node) -> bool:
	return true


func tab_matches(found: Dictionary, wanted: Dictionary) -> bool:
	return preload("res://scenes/session/ServerWorkspace.gd").encode_tab(found) == preload("res://scenes/session/ServerWorkspace.gd").encode_tab(wanted)
