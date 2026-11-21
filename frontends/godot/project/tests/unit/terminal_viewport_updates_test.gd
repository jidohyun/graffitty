extends "res://tests/unit/test_case.gd"
const Host := preload("res://scenes/TerminalHost.gd")
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")

func test_layer_owned_retained_views_survive_another_layer_finishing() -> void:
	var source := SubViewport.new()
	source.size = Vector2i(64, 64)
	var first := preload("res://scenes/CellShatter.gd").new()
	var second := preload("res://scenes/CellShatter.gd").new()
	first._capture_texture(source, 1 << 18, first)
	second._capture_texture(source, 1 << 18, second)
	var retained: SubViewport = second._captures[0]
	expect(retained != first._captures[0], "Independent owners cannot share a child viewport")
	first.free()
	expect(is_instance_valid(retained), "Finishing one layer preserves another layer's retained pixels")
	second.free()
	source.free()

func test_departing_layers_keep_output_rendering_until_the_last_hold_is_released() -> void:
	var viewport := SubViewport.new()
	var terminal := Control.new()
	viewport.add_child(terminal)
	Updates.configure(viewport, terminal)
	viewport.set_meta("terminal_frame_events", true)
	Updates.retain_live(viewport)
	Updates.retain_live(viewport)
	Updates.set_visible(viewport, false)
	Updates.set_capture_active(viewport, true)
	Updates.set_capture_active(viewport, false)
	Updates.request(viewport)
	expect(Updates.is_active(viewport) and Updates.is_transition_live(viewport), "Losing focus and destination preparation cannot freeze a moving terminal")
	expect(viewport.render_target_update_mode == SubViewport.UPDATE_ONCE, "New output still schedules a draw for the hidden live source")
	Updates.release_live(viewport)
	expect(Updates.is_active(viewport), "Another moving layer keeps the same terminal live")
	Updates.set_enabled(viewport, false)
	expect(not Updates.is_active(viewport), "Suspending the window still stops transition rendering")
	Updates.set_enabled(viewport, true)
	expect(Updates.is_active(viewport), "Resuming the window restores its live transition source")
	Updates.release_live(viewport)
	expect(not Updates.is_active(viewport) and not Updates.is_transition_live(viewport), "The final release returns the hidden terminal to sleep")
	expect(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Completed transitions stop background rendering")
	viewport.free()

func test_tab_activation_rearms_other_visible_panes() -> void:
	var host := Host.new()
	var first := SubViewport.new()
	var second := SubViewport.new()
	var a := Control.new()
	var b := Control.new()
	first.add_child(a)
	second.add_child(b)
	host.add_child(first)
	host.add_child(second)
	Updates.configure(first, a)
	Updates.configure(second, b)
	for viewport in [first, second]:
		viewport.set_meta("terminal_frame_events", true)
		viewport.set_meta("terminal_render_visible", true)
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	host.sessions = {0: {"vp": first, "term": a}, 1: {"vp": second, "term": b}}
	host.active_session_id = 1
	host.activate_session(host.sessions[1])
	expect(not first.get_meta("terminal_render_visible"), "Inactive viewport cannot remain falsely marked awake")
	Updates.set_visible(first, true)
	expect(first.render_target_update_mode == SubViewport.UPDATE_ONCE, "Visible sibling is explicitly repainted without waiting for PTY output")
	host.sessions.clear()
	host.free()

func test_workspace_focus_preserves_visible_sibling_rendering() -> void:
	var host := Host.new()
	var workspace := Control.new()
	host.workspace_view = workspace
	host.add_child(workspace)
	for id in 2:
		var viewport := SubViewport.new()
		var terminal := Control.new()
		Updates.configure(viewport, terminal)
		viewport.add_child(terminal)
		host.add_child(viewport)
		viewport.set_meta("terminal_render_visible", true)
		viewport.set_meta("terminal_frame_events", true)
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		host.sessions[id] = {"vp": viewport, "term": terminal}
	host.active_session_id = 1
	host.activate_session(host.sessions[1])
	var sibling: SubViewport = host.sessions[0].vp
	expect(sibling.get_meta("terminal_render_visible"), "Focusing the current pane preserves visible siblings")
	expect(sibling.render_target_update_mode == SubViewport.UPDATE_ONCE, "Focus cannot cancel a sibling's pending redraw")
	host.sessions.clear()
	host.free()
