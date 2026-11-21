extends "res://tests/unit/test_case.gd"
const Header := preload("res://scenes/PaneHeader.tscn")
const Session := preload("res://scenes/TerminalSession.gd")

class TitleHost extends Node:
 var pane_focus := "%1"
 var presentation_active := true
 func is_terminal_pane(key: String) -> bool: return key == "%1"
 var model: Node
 func session_model(_id: int) -> Node: return model
 func pane_title(_key: String) -> String: return model.title

class TrackingPane extends "res://scenes/WorkspacePane.gd":
 var geometry_updates := 0
 func _resize_terminal_preview() -> void: geometry_updates += 1

func make_header() -> Control:
 var header := Header.instantiate()
 header.size = Vector2(400, 30)
 header._ready()
 header.configure(true)
 header.set_touch_presentation(false)
 expect(header.view.last_error().is_empty(), "The real JavaScript header loads")
 return header

func click(header: Control, action: String) -> void:
 header.view.click(action)
 var engine: RefCounted = ClassDB.instantiate("ModHost")
 for request in engine.take_requests():
  if int(request.copy) == header.view.copy_id():
   expect(request.kind == "run" and request.name == "PaneHeaderAction", "Mod click asks its own host to act")
   header.activate(str(JSON.parse_string(request.args).action))

func test_transition_copy_paints_the_live_header() -> void:
 var header := make_header()
 var copy: Control = header.duplicate(0)
 var blank: Control = copy.get_child(header.view.get_index())
 expect(blank.copy_id() != header.view.copy_id(), "A plain duplicate has no header mod to paint")
 preload("res://scenes/WorkspacePane.gd").mirror_mod_views(header, copy)
 expect(blank.copy_id() == header.view.copy_id(), "A pane's transition copy paints the live header, so the title bar animates with it")
 copy.free()
 expect(header.view.render_now().is_empty(), "Freeing the copy leaves the live header loaded")
 header.free()

func test_header_actions_and_compact_layout() -> void:
 var header := make_header()
 header.set_hovered(true)
 var actions: Array[StringName] = []
 header.action_requested.connect(func(action: StringName): actions.append(action))
 for action in header.ACTIONS: click(header, action)
 expect(actions == [&"filetree", &"chromium", &"split_right", &"split_down", &"close"], "Mod buttons emit the existing actions")
 expect(header.part_rect("filetree").position.x < header.part_rect("chromium").position.x, "Filetree precedes Chromium")
 expect(header.part_rect("close").position.x > header.part_rect("split_down").position.x, "Close remains rightmost")
 var full_width: float = header.part_rect("title").size.x
 header.set_compact(true, true)
 expect(header.has_part("close") and not header.has_part("filetree") and not header.has_part("split_right"), "Compact chrome retains only close")
 expect(header.part_rect("title").size.x > full_width, "Hidden actions give the title their layout width")
 header.set_compact(false)
 expect(header.has_part("filetree") and header.has_part("split_right"), "Expanding restores actions immediately")
 header.configure(false)
 header.set_compact(true)
 header.set_compact(false)
 expect(not header.has_part("filetree") and not header.has_part("chromium") and not header.has_part("split_down"), "Chromium panes have no terminal-only actions")
 expect(header.has_part("close"), "Chromium panes keep close")
 header.free()

func test_compact_close_requires_focused_pane_and_ten_percent_of_title_height() -> void:
 var host := TitleHost.new()
 var pane := TrackingPane.new()
 pane.host = host
 pane.key = "%1"
 pane.header = make_header()
 pane.header.set_hovered(true)
 pane.set_compact_header(true, 240)
 expect(pane.header.has_part("close"), "At exactly ten percent the focused pane keeps close")
 pane.set_compact_header(true, 241)
 expect(not pane.header.has_part("close"), "A smaller close button has no hit target")
 host.pane_focus = "%2"
 pane.set_compact_header(true, 200)
 expect(not pane.header.has_part("close"), "Hover cannot reveal close on an unfocused compact pane")
 pane.header.free()
 pane.free()
 host.free()

func test_desktop_actions_appear_only_on_hover() -> void:
 var header := make_header()
 var resting: float = header.part_rect("title").size.x
 for action in header.ACTIONS: expect(not header.has_part(action), "Resting row has no hit target for " + action)
 header.set_hovered(true)
 expect(header.has_part("filetree") and header.has_part("close"), "Hover reveals actions")
 expect(header.part_rect("title").size.x < resting, "Shown actions reserve their width")
 header.set_touch_presentation(true)
 header.set_hovered(false)
 expect(header.has_part("close") and header.has_part("filetree"), "Touch actions do not require hover")
 header.free()

func test_touch_zoomed_out_header_has_no_close_button() -> void:
 var header := make_header()
 header.set_touch_presentation(true)
 header.set_compact(true, true)
 expect(not header.has_part("close") and header.has_part("title"), "Zoomed out on touch, the header keeps only its title: no stray-tap close")
 header.set_compact(false)
 header.set_available_width(90)
 expect(header.has_part("close") and not header.has_part("filetree"), "A merely narrow touch header at normal zoom still offers close")
 header.set_available_width(400)
 header.set_touch_presentation(false)
 header.set_compact(true)
 expect(not header.has_part("close"), "Compact headers have no close hit target unless eligible")
 header.free()

func test_agent_status_icon_only_shows_waiting_without_hover() -> void:
 var header := make_header()
 for status in ["idle", "running", "busy"]:
  header.set_agent_status(status)
  expect(not header.has_part("agent") and not header.is_processing(), "No redundant status animation for " + status)
 header.set_agent_status("waiting")
 expect(header.has_part("agent"), "Waiting shows its still icon")
 header.set_hovered(true)
 expect(header.part_rect("agent").position.x < header.part_rect("filetree").position.x, "Status precedes the action group")
 header.set_status_strip_shown(true)
 expect(not header.has_part("agent"), "The status strip owns status when shown")
 header.set_status_strip_shown(false)
 header.set_compact(true)
 expect(not header.has_part("agent"), "Compact titles have no status icon")
 header.free()

func test_touch_buttons_do_not_open_tooltips() -> void:
 var header := make_header()
 header.set_touch_presentation(true)
 header.set_filetree_open(true)
 for action in header.ACTIONS:
  expect(header.view.get_tooltip(header.part_rect(action).get_center()).is_empty(), "Touch suppresses hover help for " + action)
 expect(header.view.focus_mode == Control.FOCUS_NONE, "Chrome never steals text focus")
 header.set_touch_presentation(false)
 header.set_hovered(true)
 expect(header.view.get_tooltip(header.part_rect("split_right").get_center()).contains("Right-click"), "Desktop retains split help")
 header.free()

func test_filetree_state_does_not_emit_actions() -> void:
 var header := make_header()
 var actions: Array = []
 header.action_requested.connect(func(action): actions.append(action))
 header.set_filetree_open(true)
 expect(header.filetree_open, "Topology marks the open filetree")
 header.set_filetree_open(false)
 expect(not header.filetree_open and actions.is_empty(), "Topology changes never synthesize clicks")
 header.free()

func test_title_notifications_rebind_without_resizing_terminal() -> void:
 var host := TitleHost.new()
 var first := Session.new()
 var second := Session.new()
 host.model = first
 var pane := TrackingPane.new()
 pane.host = host
 pane.key = "%1"
 pane.add_child(pane.header)
 pane.handle.size = Vector2(500, 30)
 pane._bind_title_source()
 first.progress_changed.emit(1, 45)
 expect(pane.progress.visible and pane.progress.value == 45, "Progress updates immediately")
 first._on_title("Build complete")
 expect(pane.handle.text == "Build complete", "Titles update synchronously")
 expect(pane.geometry_updates == 0, "Title metadata cannot resize terminal geometry")
 pane.hide()
 first._on_title("Completed while hidden")
 first._state.merge({"progress_state": 1, "progress_value": 75}, true)
 first.progress_changed.emit(1, 75)
 expect(pane.handle.text == "Build complete" and pane.progress.value == 45, "Hidden panes skip visual preparation")
 pane.show()
 host.presentation_active = false
 pane._bind_title_source()
 pane._refresh_title()
 expect(pane.handle.text == "Build complete" and pane.progress.value == 45, "Suspended presentation also skips updates")
 host.presentation_active = true
 pane._bind_title_source()
 pane._refresh_title()
 expect(pane.handle.text == "Completed while hidden" and pane.progress.value == 75, "Resuming catches up")
 host.model = second
 pane._bind_title_source()
 first.progress_changed.emit(1, 90)
 expect(not pane.progress.visible, "Rebinding clears stale progress")
 second.progress_changed.emit(3, -1)
 expect(pane.progress.indeterminate, "Unknown progress remains supported")
 second._on_title("Replacement session")
 first._on_title("Detached session")
 expect(pane.handle.text == "Replacement session", "Old title source is disconnected")
 second.pin_title("Pinned")
 second._on_title("Program title")
 expect(pane.handle.text == "Pinned", "Pinned title precedence is preserved")
 pane._exit_tree()
 expect(second.title_changed.get_connections().is_empty(), "Removal disconnects titles")
 expect(second.progress_changed.get_connections().is_empty(), "Removal disconnects progress")
 pane.free(); host.free(); first.free(); second.free()

func test_narrow_touch_header_keeps_only_close_inside_clip() -> void:
 var header := make_header()
 header.set_touch_presentation(true)
 header.set_available_width(170)
 expect(not header.has_part("split_right") and not header.has_part("split_down") and header.has_part("close"), "Narrow chrome has close, not a partial toolbar")
 expect(header.part_rect("close").end.x <= 170, "Close stays inside the pane")
 header.set_available_width(400)
 expect(header.has_part("filetree") and header.has_part("chromium"), "Growing restores shortcuts")
 header.free()
