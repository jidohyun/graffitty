extends SceneTree
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	root.size = Vector2i(800, 600)
	root.gui_embed_subwindows = true
	var badge = load("res://scenes/AgentStatusBadge.gd").new()
	root.add_child(badge)
	badge.set_agent("codex", "running")
	await process_frame
	check(badge.logo.visible and not badge.provider_label.visible and badge.logo.texture != null, "Codex uses its logo")
	badge._process(0.125)
	check(badge.status_icon.rotation > 0 and badge.spinning, "Running loader rotates")
	badge.set_process(false)
	var rotation_before_layout: float = badge.status_icon.rotation
	badge.queue_sort()
	await process_frame
	await process_frame
	check(is_equal_approx(badge.status_icon.rotation, rotation_before_layout), "Layout preserves the spinner rotation")
	badge.set_agent("codex", "busy")
	for status in ["idle", "waiting", "offline", "error", "unknown"]:
		badge.set_agent("codex", status)
		check(not badge.spinning and not badge.is_processing() and badge.status_icon.texture != null and badge.status_icon.rotation == 0, status + " uses a stationary icon")
	badge.set_agent("codex", "busy")
	badge.set_agent("shell", "")
	badge.set_agent("codex", "busy")
	check(badge.spinning and badge.is_processing(), "Spinner resumes when an agent returns")
	badge.set_agent("claude", "waiting")
	check(badge.logo.visible and not badge.provider_label.visible and badge.logo.texture != null, "Claude uses its logo")
	for provider in ["codex", "claude", "opencode", "pi"]:
		badge.set_agent(provider, "busy", {"name": "Build a dashboard"})
		check(badge.logo.visible and badge.logo.texture != null and not badge.provider_label.visible, provider + " inbox agent shows only its provider icon, without repeating the pane title")
	badge.set_agent("gemini", "waiting")
	check(badge.provider_label.visible and not badge.logo.visible, "Other providers retain their identity")
	# The pane strip mod shows the same badge; its hover text is the history.
	var app := Node.new()
	app.name = "TerminalApplication"
	root.add_child(app)
	var mods = load("res://scenes/mods/ModService.gd").new()
	mods.application = app
	app.add_child(mods)
	var owner := Node.new()
	root.add_child(owner)
	var strip: Control = mods.create_pane_strip(owner, "%1")
	strip.mouse_filter = Control.MOUSE_FILTER_PASS
	strip.position = Vector2(30, 30)
	root.add_child(strip)
	var history := [
		{"at":"2030-01-01T00:30:15+00:00", "provider":"claude", "status":"busy"},
		{"at":"2030-01-01T00:31:15+00:00", "provider":"claude", "status":"idle"},
	]
	var status: Dictionary = mods.pane_resources({"status": "running", "cpu_valid": true, "cpu_percent": 0.0, "memory_current": 10485760}, "%1")
	status["agent"] = mods.agent_badge("claude", "idle", {}, history)
	mods.publish_pane(owner, "%1", status)
	await process_frame
	await process_frame
	strip.render_now()
	check("%1" in strip.texts() and "0%" in strip.texts() and "10M" in strip.texts(), "The strip shows pane, CPU and memory")
	var badge_rect: Rect2 = strip.hit_rect("agent")
	check(badge_rect.has_area(), "The strip draws the agent badge")
	# A custom node's manifest icon is its own artwork, drawn in place of a provider logo.
	var icon := {"svg": '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" fill="#ffd078"/></svg>'}
	status["agent"] = mods.agent_badge("", "idle", {"name": "Manual Prompt", "icon": icon}, [])
	mods.publish_pane(owner, "%1", status)
	await process_frame
	strip.render_now()
	check(str(status.agent.logo).begins_with("<svg") and strip.hit_rect("agent").has_area() and not "agent-name" in strip.hit_keys() and strip.last_error().is_empty(), "A node icon's SVG draws inline instead of the node's name: " + strip.last_error())
	status["agent"] = mods.agent_badge("claude", "idle", {}, history)
	mods.publish_pane(owner, "%1", status)
	await process_frame
	strip.render_now()
	badge_rect = strip.hit_rect("agent")
	var motion := InputEventMouseMotion.new()
	motion.position = strip.position + badge_rect.get_center()
	motion.global_position = motion.position
	root.push_input(motion, true)
	await process_frame
	check(root.gui_get_hovered_control() == strip, "The badge receives hover inside the click-through strip")
	var tooltip: String = strip.get_tooltip(badge_rect.get_center())
	check(tooltip.contains(badge.status_label("idle") + " (Claude)") and tooltip.contains(badge.status_label("busy") + " (Claude)") and tooltip.contains("UTC"), "Hover exposes timestamped server status history")
	await create_timer(0.8).timeout
	var popups: Array[Node] = root.find_children("*", "PopupPanel", true, false)
	check(popups.size() == 1 and popups[0].visible, "Hover opens a visible tooltip popup")
	if not popups.is_empty():
		var labels: Array[Node] = popups[0].find_children("*", "Label", true, false)
		check(labels.size() == 1 and labels[0].text == tooltip, "The visible popup contains local timestamps and status changes")
	strip.queue_free()
	quit(failures)
