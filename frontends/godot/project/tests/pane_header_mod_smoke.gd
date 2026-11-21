extends "res://tests/terminal_space_smoke.gd"
## Real projected pointer routing; no terminal is closed by this fixture.
func run() -> void:
 var host := TestHost.new()
 root.add_child(host)
 await create_timer(.6).timeout
 var view: Control = host.workspace_view
 var key: String = host.pane_focus
 var pane: Control = view.panes[key]
 var pid: int = host.sessions[host.active_session_id].term.get_shell_pid()
 var actions: Array = []
 pane.header.action_requested.disconnect(pane._header_action)
 pane.header.action_requested.connect(func(action): actions.append(action))
 # Match the reported case: only X remains, and the readable title extends
 # into its visual region. The X must win before the title's drag interceptor.
 pane.set_compact_header(true)
 pane.header.set_hovered(true)
 var title: Label = view.pane_titles[key]
 title.size.x = pane.size.x / title.scale.x
 var close_rect: Rect2 = pane.header.part_rect("close")
 check(close_rect.has_area() and not pane.header.has_part("filetree"), "Compact mod keeps only close")
 var sheet: Vector2 = pane.header.get_global_transform() * close_rect.get_center()
 var at: Vector2 = view.view_point(sheet)
 check(view._compact_header_at(at).is_empty(), "Close hit excludes the enlarged title drag area")
 var motion := InputEventMouseMotion.new()
 motion.position = view.pointer.get_transform().affine_inverse() * at
 motion.global_position = motion.position
 view._forward_pointer(motion, true)
 check(title.view.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Paint-only title retains IGNORE after ready")
 for pressed in [true, false]:
  var event := InputEventMouseButton.new()
  event.button_index = MOUSE_BUTTON_LEFT
  event.pressed = pressed
  event.position = view.pointer.get_transform().affine_inverse() * at
  event.global_position = event.position
  view._forward_pointer(event, true)
 await process_frame
 await process_frame
 check(actions == [&"close"], "A real compact close click dispatches exactly once: %s" % [actions])
 check(not pane._pressed and not pane._dragging, "Close never begins a header drag")
 check(host.sessions[host.active_session_id].term.get_shell_pid() == pid, "Routing fixture leaves the shell untouched")
 pane.header.set_compact(false)
 pane.header.set_hovered(true)
 pane.header.view.click("split_right")
 await process_frame
 await process_frame
 check(actions == [&"close", &"split_right"], "Mod actions route to their owning header: %s" % [actions])
 var title_mod: Control = title.view
 title.text = "Mod-rendered pane title"
 title._sync()
 title_mod.render_now()
 check("Mod-rendered pane title" in title_mod.texts(), "Projected title is also painted by the mod")
 check(pane.header.view.last_error().is_empty() and title_mod.last_error().is_empty(), "Header and title mod render without errors")
 host.queue_free()
 await process_frame
 await process_frame
 check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
 print("PANE_HEADER_MOD_PASS" if failures.is_empty() else "PANE_HEADER_MOD_FAIL")
 quit(0 if failures.is_empty() else 1)
