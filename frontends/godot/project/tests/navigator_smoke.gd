extends "../../../../tests/llm-e2e/replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var navigation_strokes := 0

func settle_navigation(target := "") -> void:
	await process_frame
	var deadline := Time.get_ticks_msec() + 3000
	while (host.navigator.busy or (not target.is_empty() and host.pane_focus != target)) and Time.get_ticks_msec() < deadline: await process_frame
	check(not host.navigator.busy, "Navigation completed")

func play() -> void:
	await camera_at_rest()
	check(host.navigator.configuration().get("algorithm") == "spatial", "Spatial is the default navigation algorithm")
	var commands := preload("res://scenes/CommandLineModel.gd").new()
	commands.host = host
	for algorithm in ["spatial", "nearest", "weighted"]:
		commands.set_text("navigation-" + algorithm)
		var command: Dictionary = commands.accepted()
		check(not command.is_empty(), "Algorithm is available in the command palette: " + algorithm)
		if not command.is_empty(): commands.execute(command)
		await hold(0.3) # Menu updates wait for the server decision.
		check(host.navigator.configuration().get("algorithm") == algorithm, "Command switches algorithm without restart: " + algorithm)
		for entry in host.navigator.menu_entries():
			check(host.menu_entry_state(entry).checked == (entry.label == "View::Navigation::" + algorithm.capitalize()), "Menu marks only the active algorithm")
	var source: String = host.pane_focus
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = false
	var view: Control = host.workspace_view
	Layout.find(group.tree, source).rect = Rect2(450,200,400,300)
	view.refresh()
	await host.prefix_commands.filetree.toggle(host, true)
	var tree: String = host.pane_focus
	check(tree != source, "Managed filetree opened and focused")
	if tree == source: return
	var deadline := Time.get_ticks_msec() + 60000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await keys("ctrl+l")
		await hold(0.2)
		if host.pane_focus == source:
			ready = true
			break
	check(ready,"Real Fyler calls gft at its editor edge without a bridge")
	if not ready: return
	var tree_terminal: Control = host.sessions[int(tree.substr(1))].term
	tree_terminal.keystroke.connect(func(_cell, _unicode): navigation_strokes += 1)
	group = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = false
	Layout.find(group.tree, tree).rect = Rect2(100,200,300,300)
	Layout.find(group.tree, source).rect = Rect2(450,200,400,300)
	view.refresh()
	await hold(0.2)
	for modifier in ["ctrl"]:
		host.focus_pane(tree)
		await keys(modifier + "+l")
		await settle_navigation(source)
		check(host.pane_focus == source, modifier + "-L leaves real Fyler for its owner")
		await keys(modifier + "+h")
		await settle_navigation(tree)
		check(host.pane_focus == tree, modifier + "-H returns to filetree")
		# Rotate the same real panes to exercise J/K with genuine keyboard events.
		Layout.find(group.tree, source).rect = Rect2(100,550,300,250)
		view.refresh()
		await keys(modifier + "+j")
		await settle_navigation(source)
		check(host.pane_focus == source, modifier + "-J moves down from filetree")
		await keys(modifier + "+k")
		await settle_navigation(tree)
		check(host.pane_focus == tree, modifier + "-K moves back up")
		Layout.find(group.tree, source).rect = Rect2(450,200,400,300)
		view.refresh()
	# Outer edge does nothing; filetree cursor keys remain normal terminal input.
	await keys("ctrl+h")
	await settle_navigation()
	check(host.pane_focus == tree, "No wrap at outside edge")
	check(navigation_strokes == 0, "Real Neovim navigation emits no typing signal for zoom or sparks")
	await keys("j")
	await process_frame
	check(navigation_strokes > 0, "Ordinary Neovim input still triggers typing effects")
	check(host.pane_focus == tree, "Plain j stays in the tree")
	# Shown outside panes are eligible even in a tiled workspace and with no
	# perpendicular overlap. Keyboard focus reveals them without fitting/zooming.
	group.tree.tiling = true
	var outside := Layout.find(group.tree, source)
	outside.stashed = true
	outside.rect = Rect2(view.size.x + 600, view.size.y + 400, 400, 300)
	view.show_main(true)
	view.refresh()
	await hold(0.4)
	var previous_zoom: float = view.navigation_zoom
	var previous_center: Vector2 = view.navigation_center
	await host.navigator.set_algorithm("spatial")
	await keys("ctrl+l")
	await settle_navigation(source)
	await hold(0.6)
	check(host.pane_focus == source, "Right reaches a diagonal pane outside Main View")
	check(view.navigation_center.distance_to(previous_center) > 100, "Camera pans to the outside pane")
	check(absf(view.navigation_zoom - previous_zoom) < 0.01, "Keyboard reveal preserves zoom")
	var rect: Rect2 = view.pane_rects[source]
	var shown := Rect2(view.view_point(rect.position), view.view_point(rect.end) - view.view_point(rect.position))
	check(view.viewport_content_rect().intersection(shown).get_area() >= shown.get_area() * 0.5, "At least half the destination is visible")
	previous_center = view.navigation_center
	view.reveal_navigation_target(source)
	await hold(0.4)
	check(view.navigation_center.distance_to(previous_center) < 1.0, "Visible target does not pan again")
