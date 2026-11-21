extends "../../../../replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Model := preload("res://scenes/CommandLineModel.gd")

func line() -> String:
	return host.command_line.line.text

func active_panes() -> Array[String]:
	return Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree)

func play() -> void:
	await open_tabs(3)
	await select_tab(0)
	await owner_at_rest()
	var shell := int(host.pane_focus.substr(1))
	await say("Prefix then : opens the command line listing every command")
	await keys("ctrl+a")
	await type(":")
	check(host.command_line_open() and line().is_empty(), "Prefix : opens an empty command line")
	check(host.command_line.model.rows.size() >= 10, "The popup lists the menu commands")
	var command: CanvasLayer = host.command_line
	await hold(0.1)
	var initial_width: float = command._root.size.x
	var initial_height: float = command._root.size.y
	var available: float = root.get_visible_rect().size.x - 16.0
	check(initial_width < available * 0.9, "Short command rows keep shortcuts near their descriptions")
	check(command._root.get_global_rect().end.y <= root.get_visible_rect().size.y - 8.0, "The entire popup and input stay above the window's bottom margin")
	# The words follow the interface language; the numbers are the assertion.
	var hint: String = "   ·   ".join([command.model.tr("%d tab") % 3, command.model.tr("%d.%d pane") % [3, 1]])
	check(hint in command.line.placeholder_text, "Hint shows the last tab and its last pane")
	command.model.rows[0].candidate.title = "Long command description ".repeat(30)
	command.model.rows[0].candidate.label = "long-command-name-".repeat(30)
	command._render()
	await hold(0.1)
	check(is_equal_approx(command._root.size.x, available), "Long content uses the available window width (actual=%s available=%s label=%s)" % [command._root.size.x, available, command.model.rows[0].candidate.label])
	command.model.refresh()
	command._render()
	await hold(0.1)
	check(is_equal_approx(command._root.size.x, initial_width), "The popup shrinks again when short content returns")
	if not recording:
		var original_size := root.size
		var original_content_size := root.content_scale_size
		root.content_scale_size = Vector2i(480, 720)
		root.size = Vector2i(480, 720)
		await hold(0.1)
		check(command._root.get_global_rect().end.x <= 472.0, "Resizing a narrow window keeps the command line within its margin")
		root.size = original_size
		root.content_scale_size = original_content_size
		await hold(0.1)
	await say("Window shortcuts wait while the line has the keyboard")
	var tabs: int = host.workspace_layout.tabs.size()
	await keys("cmd+t")
	await keys("cmd+w")
	check(host.workspace_layout.tabs.size() == tabs and host.command_line_open(), "Cmd+T and Cmd+W do nothing while typing")
	await say("Type part of a name: Enter runs the best prefix match")
	await type("newpaner")
	check(host.command_line.model.rows[0].candidate.label == "NewPaneRight", "newpaner ranks NewPaneRight first")
	await hold(0.1)
	check(command._root.size.y < initial_height, "Filtering shrinks the popup height to the remaining rows")
	var before: String = host.pane_focus
	await keys("enter")
	await owner_at_rest()
	var panes := active_panes()
	check(not host.command_line_open() and host.pane_focus != before and panes.size() == 2, "Enter splits right and closes the line")
	await say("A fuzzy-only match waits for an explicit choice")
	await keys("ctrl+a")
	await type(":nwpnrgt")
	check(host.command_line.model.rows[0].tier == Model.Tier.FUZZY, "nwpnrgt only matches fuzzily")
	var top: String = host.command_line.model.rows[0].candidate.label
	await keys("enter")
	check(host.command_line_open() and not host.command_line.model.status().is_empty(), "Enter keeps the line open and says why")
	await keys("tab")
	check(line() == top, "Tab previews the top match in the line")
	await keys("escape")
	check(not host.command_line_open() and active_panes().size() == 2, "Escape closes without running it")
	await say("Number mode: tab.pane, both numbered from 1")
	await select_tab(1)
	await keys("ctrl+a")
	await keys("1")
	await type(".2")
	check(host.command_line.model.rows[0].candidate.label == "1.2", "1.2 ranks tab one's second pane first")
	await keys("enter")
	await owner_at_rest()
	check(host.workspace_layout.active == host.workspace_layout.tabs[0].id and host.pane_focus == panes[1], "1.2 focuses tab one's second pane")
	await say("Pane IDs jump the same way")
	await keys("ctrl+a")
	await type(panes[0])
	check(host.command_line_open() and line() == panes[0], "Prefix % opens the line with the pane ID typed")
	await keys("enter")
	await owner_at_rest()
	check(host.pane_focus == panes[0], "%ID focuses that pane")
	await say("Overview identifies panes by position and stable ID; FitToMainArea animates home")
	var view: Control = host.workspace_view
	view.show_overview()
	# Status strips appear once the overview animation settles.
	await camera_at_rest()
	for index in panes.size():
		var key: String = panes[index]
		check(str(view.pane_status.get(key, {}).get("label", "")) == ".%d (%s)" % [index + 1, key], "Status strip shows position and stable ID for " + key)
	var start_zoom: float = view.navigation_zoom
	var target: Dictionary = view.main_frame()
	await keys("ctrl+a")
	await type(":fittomainarea")
	await keys("enter")
	check(view._inspect_tween != null and view._inspect_tween.is_running(), "FitToMainArea starts an animation")
	await hold(0.1)
	check(view.navigation_zoom > start_zoom and view.navigation_zoom < float(target.zoom), "The camera passes through intermediate zoom values")
	await hold(0.4)
	check(not view.overview and is_equal_approx(view.navigation_zoom, target.zoom) and view.navigation_center.distance_to(target.center) < 0.01, "The animation finishes at the fitted main area")
	var text := terminal_text(shell)
	check(not "newpaner" in text and not "nwpnrgt" in text, "Nothing typed into the line reached the shell")
