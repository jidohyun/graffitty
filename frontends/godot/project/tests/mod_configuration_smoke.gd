extends "res://tests/mods_fixture.gd"

func write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)

func run() -> void:
	var config := preload("res://graffitty/paths.gd").config_path()
	var folder := config.get_base_dir()
	write(folder.path_join("custom/label.js"), 'export const label = "Configured";')
	write(folder.path_join("custom/panel.js"), 'import {View, div} from "graffitty-ui"; import {props} from "graffitty"; import {label} from "./label.js"; export default class extends View { render() { return div().child(label + " " + props().message); } }')
	write(folder.path_join("custom/title.js"), 'import {View, div} from "graffitty-ui"; import {props} from "graffitty"; export default class extends View { render() { return div().child(props().message + " " + props().text); } }')
	write(config, '''[mods.agents]
entry = "custom/panel.js"
size = 260
props.message = "Agents"
[mods.builds]
entry = "custom/panel.js"
title = "Builds"
host = "panel"
place = "left"
after = "agents"
sides = ["left", "right", "bottom"]
open = true
props.message = "Builds"
[mods.resource-monitor]
open = true
after = "status-line"
size = 160
[mods.pane-header]
entry = "custom/title.js"
props.message = "Header"
[mods.extra-strip]
entry = "custom/panel.js"
host = "pane"
props.message = "Strip"
''')
	setup()
	check(preload("res://config/UserConfig.gd").validate_startup(OS.get_cmdline_user_args()).is_empty(), "Configured entries validate before startup")
	preload("res://scenes/ListDockSpace.gd").restore_open(host)
	await settle()
	var agents := PanelWindow.find(host, "agents")
	var builds := PanelWindow.find(host, "builds")
	check(agents != null and has_text(agents, "Configured Agents"), "An existing ID replaces the built-in script, including relative imports")
	check(builds != null and has_text(builds, "Configured Builds"), "A new registered panel opens automatically with its own props")
	if builds != null:
		check(builds._desktop.side == "left" and builds.dock_sides() == ["left", "right", "bottom"], "The registry controls default placement and allowed sides")
		check(space.panels.find(builds._desktop) == space.panels.find(agents._desktop) + 1, "A panel starts immediately after its configured neighbor")
		builds._publish_props()
		check(has_text(builds, "Configured Builds"), "Configured props survive resize and host-context updates")
	check(space.widths.left == space.COLLAPSED_WIDTH and space.expanded_widths.left == 260,
		"The sidebar starts as a rail; its first panel supplies the expanded width")
	var monitor := PanelWindow.find(host, "resource-monitor")
	var status := PanelWindow.find(host, "status-line")
	check(monitor._desktop.row == status._desktop.row + 1 and monitor._desktop.size.y == 160, "Band placement honors after and its preferred height")
	var embedded := preload("res://scenes/mods/EmbeddedMod.gd").create("pane-header", {"text": "First"})
	root.add_child(embedded)
	preload("res://scenes/mods/EmbeddedMod.gd").set_props(embedded, {"text": "Second"})
	embedded.render_now()
	check("Header Second" in embedded.texts(), "Embedded overrides use the registry and retain configured props")
	var strip: Control = app.mods.create_pane_strip(host, "%1")
	root.add_child(strip)
	await settle()
	check(strip is VBoxContainer and strip.get_child_count() == 2, "Additional pane mods mount alongside the built-in strip")
	check("Configured Strip" in strip.get_child(0).texts(), "The additional strip receives its configured props")
	builds._close_panel()
	await settle()
	root.remove_meta(&"dock_restored")
	preload("res://scenes/ListDockSpace.gd").restore_open(host)
	check(PanelWindow.find(host, "builds") == null, "Saved closed state wins over open-by-default configuration")
	finish("MOD_CONFIGURATION")
