extends "res://tests/unit/test_case.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Pane := preload("res://scenes/WorkspacePane.gd")
const ServerWorkspace := preload("res://scenes/session/ServerWorkspace.gd")

class Backend extends RefCounted:
	var edits: Array[Dictionary] = []
	func commit_workspace(host: Node) -> void:
		edits.append(ServerWorkspace.encode_tab(host.workspace_layout.tab(1)))

class App extends RefCounted:
	var drag := {}

class View extends "res://scenes/WorkspaceView.gd":
	func content_rect() -> Rect2: return Rect2(40, 80, 1200, 720)
	func refresh() -> void:
		pane_rects.clear()
		Layout.arrange(host.workspace_layout.tab(1).tree, content_rect(), pane_rects)

class Host extends Node:
	signal ui_changed
	var workspace_layout := Layout.new()
	var workspace_view := View.new()
	var session_backend := Backend.new()
	var application := App.new()
	var prefix_commands := preload("res://scenes/WorkspacePrefix.gd").new()
	var pane_focus := "%1"
	var layout_transaction := false
	var close_hint := "Ctrl+Shift+W"
	func is_terminal_pane(_key: String) -> bool: return true
	func shortcut_text(action: String) -> String:
		return close_hint if action == "ClosePane" else prefix_commands.shortcut_label(action)
	func _init() -> void:
		workspace_view.host = self
		add_child(workspace_view)
		prefix_commands.host = self
		prefix_commands.settings = preload("res://graffitty/config.gd").PrefixSettings.new()

func fixture(tiling := true) -> Host:
	var host := Host.new()
	host.workspace_layout.add(1, {
		"tiling": tiling, "tiling_gap": 8.0,
		"windows": [
			{"pane": "%1", "rect": Rect2(100, 120, 400, 300)},
			{"pane": "%2", "rect": Rect2(-500, 900, 320, 240)},
			{"pane": "%3", "rect": Rect2(600, 500, 320, 240)},
		],
		"tiles": {"axis": "h", "children": [
			{"pane": "%1", "weight": 3.0},
			{"axis": "v", "weight": 1.0, "children": [
				{"pane": "%2", "weight": 4.0}, {"pane": "%3", "weight": 1.0},
			]},
		]},
	})
	host.workspace_view.refresh()
	return host

func test_resize_to_fit_main_balances_and_commits_shared_layout() -> void:
	var host := fixture()
	var view := host.workspace_view
	view.overview = true
	view.navigation_center = Vector2(1500, 900)
	view.navigation_zoom = .4
	view.resize_to_fit_main()
	var rects := view.pane_rects
	expect(is_equal_approx(rects["%1"].size.x, rects["%2"].size.x), "Outer split is even")
	expect(is_equal_approx(rects["%2"].size.y, rects["%3"].size.y), "Nested split is even")
	expect(view.overview and view.navigation_center == Vector2(1500, 900) and view.navigation_zoom == .4, "Resizing does not change the camera")
	expect(host.pane_focus == "%1", "Focus stays on the original pane")
	expect(host.session_backend.edits.size() == 1, "Geometry is committed through the shared workspace backend")
	var committed := host.session_backend.edits[0]
	expect(committed.enabled and not committed.tiles.children[0].has("weight"), "Committed tiles retain mode and lose custom weights")
	host.free()

func test_resize_to_fit_main_menu_targets_clicked_free_pane_without_rejoining() -> void:
	for mode in ["floating", "stashed", "graph_floating"]:
		var host := fixture(mode != "floating")
		var tree: Dictionary = host.workspace_layout.tab(1).tree
		var selected := Layout.find(tree, "%2")
		if mode != "floating": selected[mode] = true
		var before := tree.duplicate(true)
		var pane := Pane.new()
		pane.host = host
		pane.key = "%2"
		pane._title_menu_action(7)
		var expected: Rect2 = before.windows[1].rect
		expected.size = Layout.tiling_area(tree, host.workspace_view.content_rect()).size
		expect(selected.rect == expected, "Menu resizes the clicked pane in place: " + mode)
		expect(tree.tiling == before.tiling and selected.get(mode) == before.windows[1].get(mode), "Mode and membership are preserved: " + mode)
		expect(Layout.find(tree, "%1").rect == before.windows[0].rect, "Unselected pane keeps its size")
		expect(host.pane_focus == "%1", "Menu dispatch targets its pane, not the current focus")
		expect(host.session_backend.edits.size() == 1, "Free pane geometry is shared too")
		pane.free()
		host.free()

func test_resize_to_fit_main_menu_hint_follows_prefix_rebinding() -> void:
	var host := fixture()
	var pane := Pane.new()
	pane.host = host
	pane.title_menu.add_item("Resize to fit main view", 7)
	pane.title_menu.add_item("Close pane", 0)
	pane._update_title_menu_hints()
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(0)) == "Close pane (Ctrl+Shift+W)", "Close shows Android client binding, not Meta W")
	host.close_hint = "Ctrl+Q"
	pane._update_title_menu_hints()
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(0)) == "Close pane (Ctrl+Q)", "Close hint follows custom bindings")
	host.close_hint = ""
	pane._update_title_menu_hints()
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(0)) == "Close pane", "Unbound Close has no misleading shortcut")
	var hint: String = host.prefix_commands.shortcut_label("ResizeToFitMain")
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(7)) == "Resize to fit main view (%s)" % hint, "Menu shows the default prefix sequence")
	host.prefix_commands.settings.key = KEY_B | KEY_MASK_CTRL
	host.prefix_commands.settings.bindings = {KEY_Q: "ResizeToFitMain"}
	pane._update_title_menu_hints()
	hint = host.prefix_commands.shortcut_label("ResizeToFitMain")
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(7)) == "Resize to fit main view (%s)" % hint, "Menu reflects remapped prefix and action")
	host.prefix_commands.settings.key = KEY_NONE
	pane._update_title_menu_hints()
	expect(pane.title_menu.get_item_text(pane.title_menu.get_item_index(7)) == "Resize to fit main view", "Disabled prefix has no misleading hint")
	pane.free()
	host.free()

func test_resize_to_fit_main_ignores_missing_hidden_and_busy_panes() -> void:
	var host := fixture()
	var view := host.workspace_view
	view.resize_to_fit_main("%99")
	Layout.find(host.workspace_layout.tab(1).tree, "%2").shown = false
	view.resize_to_fit_main("%2")
	view.moving = "%1"
	view.resize_to_fit_main()
	view.moving = ""
	view.tile_resize = {"tab": 1}
	view.resize_to_fit_main()
	view.tile_resize = {}
	host.application.drag = {"pane": "%1"}
	view.resize_to_fit_main()
	host.application.drag = {}
	host.layout_transaction = true
	view.resize_to_fit_main()
	expect(host.session_backend.edits.is_empty(), "No edits interrupt a gesture, transaction, or invalid target")
	host.free()
