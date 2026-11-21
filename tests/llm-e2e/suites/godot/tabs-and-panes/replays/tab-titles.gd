extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/tab-titles.md
## The command line is the feature here, so the replay types it.


func titled(index: int, title: String) -> bool:
	for i in 300:
		if titles().size() > index and titles()[index] == title:
			return true
		await process_frame
	return false


func play() -> void:
	await open_tabs(3)
	await select_tab(0)
	await camera_at_rest()
	await say("Name this tab")
	await type('"$GRAFFITTY_BIN" tab rename Build{enter}')
	check(await titled(0, "Build"), "The tab it runs in reads Build (%s)" % [titles()])
	await say("Name the second tab from here")
	await type('"$GRAFFITTY_BIN" tab rename --tab 2 Logs{enter}')
	check(
		await titled(1, "Logs") and titles()[0] == "Build",
		"The second tab reads Logs; the first still Build (%s)" % [titles()],
	)
	await say("List the tabs")
	await type('"$GRAFFITTY_BIN" tab list{enter}')
	var listed: Dictionary = await app.agent_api.dispatch(
		int(host.get_tabs()[0].id),
		"tab.list",
		{ },
	)
	var tabs: Array = listed.get("result", { }).get("tabs", [])
	check(
		tabs.size() == 3 and tabs[0].title == "Build" and tabs[0].self
		and tabs[1].title == "Logs" and tabs[0].pid > 0,
		"tab list gives positions, titles, the caller and shell pids",
	)

	await say("A program sets its own title, as shells and vim do: the name stays")
	await type("printf '\\033]0;other\\007'{enter}")
	await hold(0.6)
	check(titles()[0] == "Build", "The tab still reads Build (%s)" % [titles()])
	await say("Drag Build to the end of the bar")
	await drag(tab_grip(0), on(tab_button(2), Vector2(0.9, 0.5)), 1.2)
	await wait(0.4)
	check(titles()[2] == "Build", "The name moves with the tab (%s)" % [titles()])
	await type('"$GRAFFITTY_BIN" tab rename --tab 1 "Moved Logs"{enter}')
	check(await titled(0, "Moved Logs") and titles()[2] == "Build", "CLI positions follow the reordered tab bar")
	await type('"$GRAFFITTY_BIN" tab rename --tab-id %d Logs{enter}' % int(tabs[1].id))
	check(await titled(0, "Logs"), "CLI stable tab ID survives reordering")
	await type('"$GRAFFITTY_BIN" tab rename --target :2 "By position"{enter}')
	check(await titled(1, "By position"), "Positional target follows the visible order")
	await type('"$GRAFFITTY_BIN" tab rename --target "@%d" "By identity"{enter}' % int(tabs[2].id))
	check(await titled(1, "By identity"), "Public tab target resolves to the owner identity")

	await say("No title returns the tab to automatic")
	# Dragging keeps Build selected. Clicking that selected tab again intentionally
	# arms the workspace prefix, which would consume the command's opening quote.
	check(host.workspace_layout.active == int(host.get_tabs()[2].id), "The dragged Build tab stays selected")
	await camera_at_rest()
	await type('"$GRAFFITTY_BIN" tab rename{enter}')
	check(await titled(2, "other"), "Build reads the shell's title again (%s)" % [titles()])

	await say("Automatic names follow the focused pane and its reported path")
	var first: String = host.pane_focus
	await keys("ctrl+a")
	await keys("backslash")
	await owner_at_rest()
	var second: String = host.pane_focus
	var second_id := int(second.substr(1))
	check(second != first, "Create a second pane in the same tab")
	await type("printf '\\033]2;right-pane\\007'{enter}")
	await hold(.4)
	check(await titled(2, "right-pane"), "Automatic tab follows focused pane's OSC 2 title")
	for frame in 120:
		if host.workspace_view.panes[second].handle.text == "right-pane": break
		await process_frame
	check(host.workspace_view.panes[second].handle.text == "right-pane", "Pane shows the same OSC title")
	host.focus_pane(first)
	await hold(.2)
	check(await titled(2, "other"), "Focusing the first pane changes the automatic tab title (%s, focus %s, expected %s, first title %s)" % [titles(), host.pane_focus, first, host.session_model(int(first.substr(1))).title])
	host.focus_pane(second)
	if OS.get_name() == "Windows":
		# Let this fixture program own OSC 7; the next shell prompt must not
		# replace its deliberately reported path with the real working directory.
		await type("$env:GRAFFITTY_SHELL_SKIP_CWD='1'{enter}")
	await type("printf '\\033]2;\\007\\033]7;file://localhost/tmp/title%%20path\\007'{enter}")
	await hold(.4)
	check(await titled(2, "/tmp/title path"), "Empty OSC title falls back to decoded OSC 7 path")
	var named: Dictionary = await app.agent_api.dispatch(second_id, "window.set_title", {"title":"Pinned pane"})
	check(not named.has("error") and titles()[2] == "Pinned pane", "Explicit pane name overrides path and feeds automatic tab")
	await type("printf '\\033]0;changed-behind-pin\\007'{enter}")
	for frame in 300:
		if host.session_model(second_id)._state.get("title") == "changed-behind-pin": break
		await process_frame
	check(titles()[2] == "Pinned pane", "OSC cannot replace an explicit pane name")
	var tab_named: Dictionary = await app.agent_api.dispatch(second_id, "tab.set_title", {"title":"user@host: exact"})
	check(not tab_named.has("error") and await titled(2, "user@host: exact"), "Rename from split pane targets its containing tab")
	host.focus_pane(first)
	await hold(.2)
	check(titles()[2] == "user@host: exact", "Explicit tab name survives pane focus changes")
	await app.agent_api.dispatch(second_id, "tab.set_title", {"title":""})
	check(await titled(2, "other"), "Clearing tab name resumes the current pane title (%s, focus %s)" % [titles(), host.pane_focus])
	host.focus_pane(second)
	await app.agent_api.dispatch(second_id, "window.set_title", {"title":""})
	check(titles()[2] == "changed-behind-pin", "Clearing pane name restores the latest OSC title")
	await say("Rename the pane through its actual dialog")
	host.rename_pane(second)
	await process_frame
	var dialog: ConfirmationDialog = host.get_node("RenameDialog")
	var field: LineEdit = dialog.find_child("Title", true, false)
	# A native dialog owns a different viewport from the terminal window.
	field.grab_focus()
	field.select_all()
	for character in "Dialog pane name":
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = character.unicode_at(0)
		dialog.push_input(event, true)
		await process_frame
	check(field.text == "Dialog pane name", "Native rename input receives the complete name")
	dialog.get_ok_button().grab_focus()
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_SPACE
		event.physical_keycode = KEY_SPACE
		event.pressed = pressed
		dialog.push_input(event, true)
		await process_frame
	await hold(.3)
	if not check(not is_instance_valid(dialog) or not dialog.visible, "The native Rename button closes its dialog"): return
	await owner_at_rest()
	await type("printf '\\033]0;after-dialog\\007'{enter}")
	await host.session_backend.connection.request_action("sync", {})
	await owner_at_rest()
	check(host.session_model(second_id).pinned_title == "Dialog pane name" and titles()[2] == "Dialog pane name", "Dialog rename survives OSC and owner topology updates")
	check(await host.set_pane_title(second, ""), "Clearing the dialog name is acknowledged by the owner")
	check(await titled(2, "after-dialog"), "Clearing the dialog name restores the latest program title")
