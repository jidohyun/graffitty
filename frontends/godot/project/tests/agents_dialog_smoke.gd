extends "res://tests/mods_fixture.gd"
## The Agents window renders the Agents mod from published rows: sections,
## captions, connected panes, fold, pin and focus. Isolated UI fixture.

func run() -> void:
	setup()
	var now := int(Time.get_unix_time_from_system())
	for index in 5:
		app.agents.rows.append({"id": "test-%d" % index, "key": "%%%d" % index,
			"title": ["Review the release", "Permission needed", "Tests complete", "Implement the agent list", "Ready for a task"][index],
			"provider": ["claude", "pi", "codex", "pi", "opencode"][index],
			"status": ["idle", "blocked", "done", "working", "idle"][index],
			"section": ["Pinned", "Needs you", "Done", "Working", "Idle"][index],
			"at": now - index * 70, "focused": false, "pinned": index == 0, "remote": "", "session": ""})
	app.agents.trees["test-3"] = [{"key": "%9", "kind": "chromium", "title": "Docs", "status": "", "icon": "chromium", "lines": ["└"], "host_id": host.get_instance_id()}]
	app.agents.changed.emit()
	var dialog: Window = PanelWindow.open(host, "agents")
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Agents mod loads and renders: " + dialog.view.last_error())
	check(is_instance_valid(dialog._desktop) and dialog._desktop.side == "left" and not dialog.visible, "Agents docks into the left sidebar by default")
	# The rest exercises the floating window, as a title double-click leaves it.
	dialog.float_native()
	await settle()
	check(dialog.visible and dialog._desktop.side.is_empty(), "Undocking floats the window again")
	check(not dialog.exclusive and not dialog.unresizable, "Non-modal, draggable/resizable normal window")
	var shown := texts(dialog)
	check("Pinned  1" in shown and "Needs you  1" in shown and "Working  1" in shown, "Five section headers with counts: %s" % [shown])
	check("Review the release" in shown and "Docs" in shown, "Rows and connected panes are drawn")
	check("<1m" in shown and "2m" in shown, "Herdr elapsed times")
	var keys: PackedStringArray = dialog.view.hit_keys()
	check("sub-test-3|%9" in keys and "fold-test-3" in keys, "Connected pane row and its fold chevron exist")
	dialog.view.click("fold-test-3")
	await settle()
	check(not "sub-test-3|%9" in dialog.view.hit_keys() and "1" in texts(dialog), "Folding hides connected panes and shows their count")
	dialog.view.click("sec-Done")
	await settle()
	check(not "Tests complete" in texts(dialog), "Group folds")
	dialog.view.click("sec-Done")
	await settle()
	check("Tests complete" in texts(dialog), "Group unfolds")
	# Hovering a row swaps its time for the pin; pinning never focuses.
	var row: Rect2 = dialog.view.hit_rect("ag-test-0")
	dialog.view.hover_at(row.get_center())
	await settle()
	dialog.view.render_now()
	check("pin-test-0" in dialog.view.hit_keys() and not "time-test-0" in dialog.view.hit_keys(), "Hover shows the pin in place of the time")
	dialog.view.click("pin-test-0")
	pump()
	check(app.agents.pinned.get("test-0") == false and app.agents.focused.is_empty(), "Pin does not select")
	dialog.view.click("ag-test-3")
	pump()
	check(app.agents.focused == "test-3", "Row focuses its agent")
	dialog.view.click("fold-test-3")
	await settle()
	dialog.view.render_now()
	dialog.view.click("sub-test-3|%9")
	pump()
	check(host.focused_key == "%9", "Connected pane row focuses that pane in its host")
	check(dialog.visible, "Selecting a row leaves Agents open")
	# Title-only updates re-render without losing fold state.
	dialog.view.click("fold-test-3")
	app.agents.rows[0].title = "Retitled"
	app.agents.changed.emit()
	await settle()
	check("Retitled" in texts(dialog) and not "sub-test-3|%9" in dialog.view.hit_keys(), "Title updates keep the folded state")
	# Captions: one per consecutive server/session; local shows session only.
	var contexts := [["", "work"], ["", "work"], ["build", "api"], ["build", "api"], ["build", "web"]]
	for index in 5:
		app.agents.rows[index].section = "Idle"
		app.agents.rows[index].status = "idle"
		app.agents.rows[index].remote = contexts[index][0]
		app.agents.rows[index].session = contexts[index][1]
	app.agents.changed.emit()
	await settle()
	shown = texts(dialog)
	check("work" in shown and "build · api" in shown and "build · web" in shown and shown.count("build · api") == 1, "Repeated server/session is skipped; local omits the server name: %s" % [shown])
	var full_caption: float = dialog.view.hit_rect("ctx-test-0").size.y
	var tall: Vector2i = dialog.size
	dialog.size = Vector2i(tall.x, 120)
	await settle()
	dialog.view.render_now()
	check(full_caption > 8.0 and dialog.view.hit_rect("ctx-test-0").size.y == full_caption, "An overflowing list scrolls instead of squashing captions")
	dialog.size = tall
	await settle()
	dialog.set_compact(true)
	await settle()
	shown = texts(dialog)
	check("1" in shown and "5" in shown and not "Idle  5" in shown, "Compact mode has numbered agents, no groups")
	check(not dialog.footer.visible, "Compact mode removes the footer")
	check(dialog.view.get_tooltip(dialog.view.hit_rect("ag-test-2").get_center()) == "build · api · Tests complete", "Compact tooltip identifies the remote computer, session and agent")
	check(dialog.view.get_tooltip(dialog.view.hit_rect("ag-test-0").get_center()) == dialog.tr("This Computer") + " · work · Retitled", "Local agent tooltip identifies this computer")
	dialog.view.click("ag-test-2")
	pump()
	check(app.agents.focused == "test-2", "Compact rows focus the same agent")
	dialog.set_compact(false)
	await settle()
	check("Idle  5" in texts(dialog), "Expanding restores grouped rows")
	app.agents.rows.clear()
	app.agents.changed.emit()
	await settle()
	check(has_text(dialog, "No agent status yet"), "Empty list explains itself")
	dialog.queue_free()
	await settle()
	finish("AGENTS_DIALOG")
