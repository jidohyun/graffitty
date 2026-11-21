extends "res://tests/terminal_space_smoke.gd"
## godot --headless --path . --script tests/flat_2d_scrollbar_smoke.gd -- --touch-controls

func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(0.5).timeout
	check(host.switch_world("flat-2d"), "Flat 2D loads")
	await create_timer(0.5).timeout
	var bar: VScrollBar = host.world.scrollbar
	var view: Control = host.workspace_view
	check(bar.get_viewport() == view.get_viewport(), "Scrollbar receives input in the host viewport")
	check(bar.is_in_group(&"touch_chrome"), "Android treats scrollbar as directly interactive chrome")
	check(bar.custom_minimum_size.x == 0, "Scrollbar uses the normal theme width on every platform")
	# A deterministic remote terminal supplies history without shell startup races.
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	host.add_child(terminal)
	terminal.hide()
	var session := preload("res://scenes/TerminalSession.gd").new()
	session.configure(host.active_session_id, terminal)
	host.add_child(session)
	var original: Node = host.sessions[host.active_session_id].model
	host.sessions[host.active_session_id].model = session
	session.changed.connect(host.ui_changed.emit)
	terminal.remote_feed_stream("scrollbar history\r\n".repeat(180).to_utf8_buffer(), 80, 20, false, false)
	await process_frame
	await process_frame
	host.ui_changed.emit()
	check(bar.visible and bar.max_value > bar.page, "Scrollbar appears for terminal history")
	bar.value = 12.5
	check(is_equal_approx(host.session_model(host.active_session_id).scroll_offset, 12.5), "Scrollbar changes native fractional scroll position")
	terminal.scroll_to_position(24.0)
	await process_frame
	await process_frame
	check(is_equal_approx(bar.value, 24.0), "Terminal scrolling updates scrollbar")
	check(is_equal_approx(bar.get_global_rect().end.x, view.get_global_rect().end.x), "Scrollbar hugs the right edge")
	check(bar.get_global_rect().position.y >= view.tab_bar.get_global_rect().end.y, "Scrollbar starts below tab chrome")
	view.tab_bar.hide()
	await process_frame
	check(is_zero_approx(bar.offset_top), "Hidden tabs allow scrollbar to fill the height")
	view.tab_bar.show()
	terminal.remote_feed_stream("\u001b[?1049h".to_utf8_buffer(), 80, 20, false, false)
	await process_frame
	await process_frame
	check(not bar.visible, "Alternate-screen apps hide history scrollbar")
	host.sessions[host.active_session_id].model = original
	check(host.switch_world(""), "Switch away from Flat 2D")
	await process_frame
	check(not is_instance_valid(bar), "World switching removes its host-mounted scrollbar")
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No lifecycle errors: %s" % [error_watch.errors])
	quit(0 if failures.is_empty() else 1)
