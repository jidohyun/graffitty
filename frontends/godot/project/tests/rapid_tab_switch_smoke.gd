extends SceneTree
## Sample actual terminal ink on every displayed frame during interrupted Flat 3D zooms.

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()


func fill_terminal(term: Node, rgb: String) -> void:
	var row := "\u001b[38;2;%sm%s\u001b[0m\r\n" % [rgb, "█".repeat(64)]
	var payload := Marshalls.raw_to_base64(row.repeat(40).to_utf8_buffer())
	if OS.get_name() == "Windows":
		term.send_text("[Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))\r" % payload)
	else:
		# Keep the command below the PTY's canonical input limit.
		var escaped := "\\033[38;2;%sm%s\\033[0m\\n" % [rgb, "█".repeat(64)]
		term.send_text("i=0; while [ $i -lt 40 ]; do printf '%s'; i=$((i+1)); done\n" % escaped)


func ink_counts() -> Vector2i:
	var image := root.get_texture().get_image()
	image.resize(190, 120, Image.INTERPOLATE_BILINEAR)
	var counts := Vector2i.ZERO
	for y in range(20, 105):
		for x in range(10, 185):
			var pixel := image.get_pixel(x, y)
			if pixel.g - pixel.r > 0.1: counts.x += 1
			if pixel.r - pixel.g > 0.1: counts.y += 1
	return counts


func run() -> void:
	root.size = Vector2i(760, 480)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	if wrapper.host == null: await wrapper.host_ready
	var host: Node = wrapper.host
	host.instant_workspace_switch = true
	await wrapper.connection.request_action("create", {"kind": "tab"})
	var deadline := Time.get_ticks_msec() + 10000
	while host.get_tabs().size() != 2 and Time.get_ticks_msec() < deadline: await process_frame
	if host.get_tabs().size() != 2:
		printerr("Two test tabs did not open")
		quit(1)
		return
	var tabs: Array = host.workspace_layout.tabs
	# Warm both tabs and verify the markers before measuring the transition.
	for i in 2:
		host.select_workspace(tabs[i].id)
		fill_terminal(host.active_terminal(), "0;255;0" if i == 0 else "255;0;0")
		deadline = Time.get_ticks_msec() + 10000
		await RenderingServer.frame_post_draw
		while ink_counts()[i] < 500 and Time.get_ticks_msec() < deadline:
			await process_frame
			await RenderingServer.frame_post_draw
		if ink_counts()[i] < 500:
			printerr("Missing terminal marker in tab ", i)
			quit(1)
			return
	host.instant_workspace_switch = false
	host.world.tab_fx = true
	host.world.fx_cfg.set_option("scene.tab_switch", "effect", "push_pull")
	host.world.film_dt = 1.0 / 60.0
	var selected := 1
	var minimum_ink := 190 * 120
	var counts := Vector2i.ZERO
	for frame in 120:
		await process_frame
		if frame >= 3 and frame <= 67 and (frame - 3) % 4 == 0:
			selected = 1 - selected
			host.select_workspace(tabs[selected].id)
		await RenderingServer.frame_post_draw
		counts = ink_counts()
		minimum_ink = mini(minimum_ink, counts.x + counts.y)
	var passed: bool = minimum_ink > 100 and counts[selected] > 500 and counts[1-selected] < 100 and host.world.tab_fx_stale.is_empty()
	print("Minimum displayed terminal pixels: ", minimum_ink, ", final markers: ", counts)
	print("RAPID_TAB_SWITCH_PASS" if passed else "RAPID_TAB_SWITCH_FAIL")
	quit(0 if passed else 1)
