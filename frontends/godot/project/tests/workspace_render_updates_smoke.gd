extends SceneTree
## Windowed: checks actual composited pixels and idle render counts.
## godot --path . --script tests/workspace_render_updates_smoke.gd -- --shell=/bin/cat --no-fx
var host: Node
var draws := 0
var failures := 0
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()

func _initialize() -> void:
	diagnostic_guard.install(self)
	var isolated := OS.get_cache_dir().path_join("render-updates-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated)
	OS.set_environment("XDG_STATE_HOME", isolated)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("[replay] PASS " if ok else "[replay] FAIL ", message)
	if not ok: failures += 1

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func pixels() -> int:
	return hash(root.get_texture().get_image().get_data())

func chromium_checks() -> void:
	pass

func settle_seconds() -> float:
	var camera_settings: Dictionary = host.world.fx_cfg.scene.camera
	var settle: float = host.world.fx_idle_after + host.world.fx_leave_duration + 3.0 * maxf(
		float(camera_settings.adaptive_zoom_in_seconds), float(camera_settings.adaptive_zoom_out_seconds))
	return maxf(10.0, settle)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test requires a window and real rendering")
		quit(1)
		return
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	if wrapper.host == null: await wrapper.host_ready
	host = wrapper.host
	if "--flat-2d" in OS.get_cmdline_user_args(): host.switch_world("flat-2d")
	root.content_scale_factor = 1.0
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_size = Vector2i(1000, 650)
	root.min_size = Vector2i(1000, 650)
	root.max_size = Vector2i(1000, 650)
	root.size = Vector2i(1000, 650)
	var terminal: Control = host.sessions[host.active_session_id].term
	terminal.configure_advanced({"cursor_blink": 0})
	RenderingServer.frame_post_draw.connect(func(): draws += 1)
	await wait(settle_seconds())
	root.grab_focus()
	await wait(0.3)
	check(root.has_focus(), "Rendering checks have a focused window")
	check(Engine.max_fps == 120, "Focused application uses the default 120 FPS cap")
	check(OS.low_processor_usage_mode, "Application enables rendering on demand")
	var before := draws
	await wait(1.0)
	check(root.has_focus(), "Window stays focused during the idle sample")
	check(draws - before <= 2, "Static workspace stops drawing: %d frames" % (draws - before))
	var image := pixels()
	terminal.send_text("ON_DEMAND_VISIBLE")
	await wait(0.3)
	check("ON_DEMAND_VISIBLE" in str(terminal.get_text(false).get("text", "")), "PTY output is processed while rendering sleeps")
	check(pixels() != image, "PTY output reaches the final window pixels")
	terminal.configure_advanced({"cursor_blink": 1, "cursor_blink_interval_ms": 80})
	before = draws
	await wait(0.5)
	check(draws - before >= 3, "Cursor blinking wakes rendering: %d frames, terminal focus %s, window focus %s" % [draws-before, terminal.has_focus(), root.has_focus()])
	terminal.configure_advanced({"cursor_blink": 0})
	host.workspace_view.show_overview()
	await wait(0.3)
	image = pixels()
	before = draws
	host.workspace_view.inspect_pane(host.pane_focus)
	await wait(0.5)
	check(draws - before >= 5 and pixels() != image, "Pane fit animates and updates the final window")
	var navigation_deadline := Time.get_ticks_msec() + 5000
	while host.workspace_view._inspect_tween != null and host.workspace_view._inspect_tween.is_running() and Time.get_ticks_msec() < navigation_deadline:
		await process_frame
	await wait(settle_seconds())
	before = draws
	await wait(1.0)
	check(draws - before <= 2, "Workspace sleeps again after navigation: %d frames" % (draws - before))
	host.world._set_world_awake(false)
	await wait(0.1)
	host.world._set_world_awake(true)
	await wait(0.1)
	check(Engine.max_fps > 0 and Engine.max_fps <= 120, "Focus changes preserve the frame cap")
	# Desktop focus may move to another application during an automated run.
	# Keep the rendering workload active independently of that external state.
	host.world.background_skip = false
	host.world._set_world_awake(true)
	host.world.fx_enabled = true
	await wait(0.1)
	root.grab_focus()
	await wait(0.2)
	terminal.grab_focus()
	var key := InputEventKey.new()
	key.keycode = KEY_X
	key.unicode = 120
	key.pressed = true
	before = draws
	image = pixels()
	root.push_input(key, true)
	key = key.duplicate()
	key.pressed = false
	root.push_input(key, true)
	await wait(0.7)
	check(host.world.world_awake, "Typing rendering workload remains active")
	check(draws - before >= 10 and pixels() != image, "Typing effects animate with rendering on demand: %d frames, typing %s, text %s" % [draws-before, host.world.fx_typing, terminal.get_text(false).get("text", "")])
	# Adaptive framing has its own slow return. Sample idle after all configured
	# eases settle, rather than during the tail of the default ten-second ease.
	await wait(settle_seconds())
	before = draws
	await wait(1.0)
	check(draws - before <= 2, "Typing effects return to idle rendering: %d frames" % (draws - before))
	if draws - before > 2:
		print("IDLE_EFFECTS ", host.world.fx_typing, " ", host.world.fx_prev_frame)
	await chromium_checks()
	failures += diagnostic_guard.failures.size()
	print("WORKSPACE_RENDER_UPDATES_PASS" if failures == 0 else "WORKSPACE_RENDER_UPDATES_FAIL")
	quit(failures)
