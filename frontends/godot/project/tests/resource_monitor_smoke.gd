extends "res://tests/mods_fixture.gd"
## The Resource Monitor: every pane of every window with its samples, published
## by the mod service through the Rust row model, and a click focuses the pane.
const PaneTree := preload("res://scenes/WorkspaceLayout.gd")

func run() -> void:
	setup()
	host.workspace_layout.tabs = [{"id": 1, "tree": {"windows": [PaneTree.leaf("%1"), PaneTree.leaf("%2")]}}]
	host.pane_focus = "%2"
	app.mods.publish_window(host)
	var dialog: Window = PanelWindow.open(host, "resource-monitor")
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Resource Monitor mod loads: " + dialog.view.last_error())
	check(dialog._desktop.side == "bottom", "Resource Monitor docks in the bottom band by default")
	check(is_equal_approx(dialog.background_opacity, 0.78), "Mod configuration sets the background opacity")
	var docked: StyleBoxFlat = dialog._desktop.get_theme_stylebox("panel")
	check(is_equal_approx(docked.bg_color.a, 0.78) and dialog._body.get_theme_stylebox("panel").bg_color.a == 0.0, "Docked, one translucent surface paints, not two stacked")
	dialog.float_native()
	await settle()
	var composited := preload("res://graffitty/window_transparency.gd").available(dialog.get_window_id())
	check(dialog.force_native and dialog.transparent == composited and dialog.transparent_bg == composited and dialog.translucent() == composited, "Floating window transparency follows the active compositor")
	check(is_equal_approx(dialog._frame.get_theme_stylebox("panel").bg_color.a, 0.78 if composited else 1.0), "The floating frame uses the available opacity")
	var opaque: Window = PanelWindow.open(host, "pane-status")
	await settle()
	opaque.background_opacity = 1.0
	opaque.apply_background()
	opaque.float_native()
	await settle()
	check(opaque._frame.get_theme_stylebox("panel").bg_color.a == 1.0, "Full background opacity paints an opaque frame")
	opaque._close_panel()
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2(640, 790)))
	await settle()
	for needle in ["Title", "CPU", "RAM", "#procs", "PID", "Server", "Session", "Pane %1", "Pane %2", "12%", "1M", "123", "This Computer", "Total · 2 panes", "24%", "2M", "4"]:
		check(has_text(dialog, needle), "Table shows %s: %s" % [needle, texts(dialog)])
	host.sample.cpu = 30.0
	host.sample.snapshot_changed.emit(host.sample.snapshot())
	await settle()
	check(has_text(dialog, "30%") and has_text(dialog, "60%"), "A new sample re-renders the rows and the total: %s" % [texts(dialog)])
	host.workspace_layout.tabs = [{"id": 1, "tree": PaneTree.leaf("%1")}]
	host.ui_changed.emit()
	await settle()
	check(not has_text(dialog, "Pane %2") and has_text(dialog, "Total · 1 pane"), "A closed pane leaves the table")
	var row := ""
	for key in dialog.view.hit_keys():
		if str(key).begins_with("row-") and not "/" in str(key): row = str(key)
	check(not row.is_empty(), "The pane has a row")
	check(dialog.view.click(row), "The row takes a click")
	pump()
	check(host.focused_key == "%1", "Clicking a row focuses its pane")
	await settle(8)
	var reflows := space.reflows
	var publications: int = app.mods.session_publications
	await create_timer(0.65).timeout
	check(space.reflows == reflows, "An idle dock does not recalculate layout")
	check(app.mods.session_publications == publications, "Idle mods do not rebuild session data")
	PanelWindow.toggle(host, "resource-monitor")
	await settle()
	check(PanelWindow.find(host, "resource-monitor") == null, "The panel closes")
	finish("RESOURCE_MONITOR")

