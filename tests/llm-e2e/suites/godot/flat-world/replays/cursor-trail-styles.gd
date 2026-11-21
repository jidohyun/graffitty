extends "../../../../replay/replay.gd"

func play() -> void:
	await labelled_tabs(["TRAILS"])
	var id: int = int(host.pane_focus.substr(1))
	var pid: int = host.sessions[id].term.get_shell_pid()
	for world_path in ["", "flat-2d"]:
		host.switch_world(world_path)
		await hold(.2)
		for style in ["smear", "blaze", "lightning", "off"]:
			var entries: Array = host.menu_entries.filter(func(entry): return entry.label == "View::Cursor Trail::" + style.capitalize())
			check(entries.size() == 1, "Menu exposes " + style)
			if entries.size() != 1: continue
			host._run_menu_action(entries[0])
			await hold(.1)
			check(host.cursor_trail_style() == style, "Live menu selection applies " + style)
			check(entries[0].checked.call(host), "Selected menu item is checked")
			var renderer = host.world.get("effects_2d") if world_path == "flat-2d" else host.world.get("terminal_effects")
			check(renderer.trail.delay_ms == 0 if style == "off" else renderer.trail.style == style, "Renderer receives menu selection")
		host.set_cursor_trail_style("lightning")
		host.switch_world("flat-2d" if world_path == "" else "")
		await hold(.2)
		check(host.cursor_trail_style() == "lightning", "Selection survives switching worlds")
	check(host.sessions[id].term.get_shell_pid() == pid, "Style changes preserve running shell")
