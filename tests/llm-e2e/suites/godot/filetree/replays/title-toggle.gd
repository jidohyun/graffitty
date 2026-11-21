extends "../../tabs-and-panes/replays/main-area-tiling.gd"
var owner_config := ""
func _initialize() -> void:
	owner_config = OS.get_environment("XDG_CONFIG_HOME").replace("\\", "/")
	super._initialize()

## The header mod paints the open filetree action #4da3ff; read it back from
## the rendered window, where the action's rectangle is measured.
func filetree_icon_is_blue(key: String) -> bool:
	var center := await on_header(key, "filetree")
	var header: Control = host.workspace_view.panes[key].header
	var half: Vector2 = header.part_rect("filetree").size * 0.5
	var picture := await screen_image()
	var scale := Vector2(picture.get_size()) / root.get_visible_rect().size
	var blue := 0
	for y in range(int((center.y - half.y) * scale.y), int((center.y + half.y) * scale.y)):
		for x in range(int((center.x - half.x) * scale.x), int((center.x + half.x) * scale.x)):
			var pixel := picture.get_pixel(x, y)
			if pixel.b > 0.8 and pixel.g > 0.45 and pixel.g < 0.8 and pixel.r < 0.5: blue += 1
	return blue >= 12


func play() -> void:
	await say("Prepare real Fyler with a different root")
	var plugin := OS.get_environment("FYLER_TEST_PLUGIN")
	check(FileAccess.file_exists(plugin.path_join("lua/fyler.lua")), "Real Fyler plugin fixture is available")
	if not FileAccess.file_exists(plugin.path_join("lua/fyler.lua")): return
	var directory := owner_config.path_join("filetree-root % test")
	var child := directory.path_join("child")
	DirAccess.make_dir_recursive_absolute(child)
	var config := owner_config.path_join("nvim-e2e-filetree")
	DirAccess.make_dir_recursive_absolute(config)
	var init := FileAccess.open(config.path_join("init.lua"), FileAccess.WRITE)
	init.store_string("vim.opt.swapfile=false\nvim.opt.rtp:prepend(%s)\nrequire('fyler').setup({kind='replace',follow_current_file=false,use_as_default_explorer=false,integrations={icon=function() return '' end}})\nvim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.schedule(function() require('fyler').open({root_path=%s,kind='replace'}) end) end})\n" % [JSON.stringify(plugin), JSON.stringify(child)])
	init.close()
	var owner: int = host.active_session_id
	var key := "%%%d" % owner
	var original_pid: int = host.sessions[owner].term.get_shell_pid()
	await owner_at_rest()
	var pane: Control = host.workspace_view.panes[key]
	check(not pane.header.filetree_open, "Filetree button starts off")
	await say("Open with the header button")
	# Title actions appear once the pointer is over the title row.
	await hover_header(key)
	check(pane.header.has_part("filetree"), "Hovering the title shows its actions")
	await click(await on_header(key, "filetree"))
	var deadline := Time.get_ticks_msec() + 15000
	var tree := -1
	while Time.get_ticks_msec() < deadline:
		for id in host.sessions:
			if host.sessions[id].term.get_meta("filetree_owner", -1) == owner: tree = id
		if tree >= 0 and host.workspace_view.panes.has("%%%d" % tree) and host.session_model(tree).title == child: break
		await process_frame
	check(tree >= 0, "Header button creates the connected filetree")
	if tree < 0: return
	check(pane.header.filetree_open, "Owner button is on")
	check(await filetree_icon_is_blue(key), "Active filetree icon is blue")
	var tree_pane: Control = host.workspace_view.panes["%%%d" % tree]
	check(host.session_model(tree).title == child, "Title is the actual Fyler root: got " + host.session_model(tree).title + " expected " + child)
	if host.session_model(tree).title != child:
		print(await host.session_backend.connection.remote_call(tree, "terminal.get_text", {}))
	await say("Change Fyler root independently")
	# Actual terminal input invokes Fyler's parent-root mapping.
	host.focus_pane("%%%d" % tree)
	await type("-")
	deadline = Time.get_ticks_msec() + 5000
	while host.session_model(tree).title != directory and Time.get_ticks_msec() < deadline: await process_frame
	check(host.session_model(tree).title == directory, "Title follows Fyler root navigation")
	await say("Toggle off closes the pane")
	host.focus_pane(key)
	await owner_at_rest()
	await camera_at_rest()
	await hold(0.5)
	await click(await on_header(key, "filetree"))
	deadline = Time.get_ticks_msec() + 10000
	while host.sessions.has(tree) and Time.get_ticks_msec() < deadline: await process_frame
	check(not host.sessions.has(tree), "Second click closes the live filetree pane")
	check(not pane.header.filetree_open, "Owner button returns to off")
	check(host.sessions[owner].term.get_shell_pid() == original_pid, "Original shell survives toggling")
