extends SceneTree
var failures := 0
class FakeHost extends Node:
 signal ui_changed
 var world_viewport: Viewport:
  get: return get_viewport()
 var workspace_view = null
 var workspace_layout = {'active':1}
 var prefix_commands = {'active':false}
 var items: Array = []
 var closed_ids: Array = []
 func get_tabs(_session_only := false) -> Array: return items.duplicate(true)
 func select_workspace(id: int) -> void:
  workspace_layout.active = id
  ui_changed.emit()
 func request_close_tab(id): closed_ids.append(id)
 func move_session(_id, _index): pass
 func create_session(): pass
 func shortcut_text(_action: String) -> String: return ''
func _initialize(): run.call_deferred()
func check(ok: bool, label: String):
 print('PASS ' if ok else 'FAIL ',label)
 if not ok: failures += 1
func run():
 root.unfocusable = true
 root.gui_embed_subwindows = true
 root.size = Vector2i(700,400)
 if DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE):
  root.get_node('TerminalApplication').configure_window_scale(root)
  root.size = Vector2i(Vector2(700,400) * root.content_scale_factor)
  root.extend_to_title = true
 var host := FakeHost.new()
 root.add_child(host)
 for i in 40: host.items.append({'id':i+1,'title':'Workspace %d' % (i+1),'progress_state':0,'progress_value':-1})
 var strip = load('res://scenes/TerminalTabBar.tscn').instantiate()
 strip.bind_host(host)
 root.add_child(strip)
 strip.size = Vector2(650,34)
 for i in 5: await process_frame
 check(is_equal_approx(strip.size.y, 42.0), 'Default desktop tab bar matches the 42px Chrome frame')
 check(is_equal_approx(strip.tabs.buttons[1].size.y, 34.0), 'Default tabs are 34px tall with an 8px top gap')
 check(strip.navigation.next_tabs.visible and strip.navigation.all_tabs.visible, 'Overflow exposes navigation and a complete tab menu')
 check(strip.navigation.all_tabs.get_global_rect().end.x < strip.tabs.global_position.x, 'All-tabs dropdown precedes the tabs')
 if root.extend_to_title:
  var safe := DisplayServer.window_get_safe_title_margins(root.get_window_id())
  var scale := root.get_final_transform().get_scale()
  check(absf(strip.navigation.all_tabs.position.x * scale.x - safe.x - 8 * scale.x) < 1, 'Native traffic-light margin uses the current display scale')
 strip.navigation.next_tabs.pressed.emit()
 await process_frame
 check(strip.tabs.scroll_horizontal > 0, 'Next arrow reveals offscreen tabs')
 strip.navigation.previous_tabs.pressed.emit()
 await process_frame
 check(strip.tabs.scroll_horizontal == 0, 'Previous arrow returns to beginning')
 var wheel := InputEventMouseButton.new()
 wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
 wheel.pressed = true
 wheel.factor = 1.0
 strip.tabs._tab_input(1, strip.tabs.buttons[1], wheel)
 check(strip.tabs.scroll_horizontal > 0, 'Wheel over a tab scrolls the horizontal strip')
 var before_pan: int = strip.tabs.scroll_horizontal
 var pan := InputEventPanGesture.new()
 pan.delta = Vector2(2,0)
 strip.tabs._tab_input(1, strip.tabs.buttons[1], pan)
 check(strip.tabs.scroll_horizontal > before_pan, 'Trackpad gesture over a tab scrolls the strip')
 strip._populate_tab_menu()
 check(strip.navigation.menu.list.item_count == 40, 'Menu lists all forty tabs')
 strip.navigation.all_tabs.pressed.emit()
 await process_frame
 strip.navigation.menu.list.item_clicked.emit(39, Vector2.ZERO, MOUSE_BUTTON_LEFT)
 for i in 5: await process_frame
 var last: Control = strip.tabs.buttons[40]
 check(host.workspace_layout.active == 40, 'Menu selects last tab by stable ID')
 check(last.position.x + last.size.x <= strip.tabs.scroll_horizontal + strip.tabs.size.x + 1, 'Selected last tab scrolls into view')
 if DisplayServer.get_name() != 'headless':
  RenderingServer.force_draw(false)
  root.get_texture().get_image().save_png('/tmp/tab-overflow.png')
 host.items = host.items.slice(0,2)
 host.workspace_layout.active = 1
 host.ui_changed.emit()
 for i in 60:
  await process_frame
  if not strip.tabs._settling: break
 check(not strip.navigation.next_tabs.visible and not strip.navigation.previous_tabs.visible, 'Scroll arrows disappear when tabs fit')
 check(strip.navigation.all_tabs.visible, 'All-tabs dropdown remains available when tabs fit')
 strip._populate_tab_menu()
 check(strip.navigation.menu.list.item_count == 2, 'Dropdown updates after tabs close')
 check(strip.tabs.plus.position.x >= strip.tabs.position.x + strip.tabs.size.x, 'New-tab button follows the tabs')
 var close: Button = strip.tabs.buttons[1].get_node('Close')
 check(absf(close.get_global_rect().get_center().y - strip.tabs.plus.get_global_rect().get_center().y) < 1, 'Tab close and plus icons share a vertical center')
 for button in [strip.navigation.all_tabs, strip.tabs.plus, close]:
  var motion := InputEventMouseMotion.new()
  motion.position = button.get_global_rect().get_center()
  root.push_input(motion, true)
  check(button.is_hovered(), '%s receives hover in its visible position' % button.name)
 var center := close.get_global_rect().get_center()
 strip.tabs.elastic.fixed_time = 1.0
 for phase in ["began", "changed", "ended"]:
  var pull := InputEventPanGesture.new()
  pull.position = center
  pull.delta = Vector2(-40, 0) if phase != "ended" else Vector2.ZERO
  pull.set_meta("scroll_phase", phase)
  pull.set_meta("touch_travel", true)
  root.push_input(pull, true)
 check(strip.tabs.stretch < 0, 'Trackpad over the close button pulls the strip past its left edge')
 strip.tabs.elastic.fixed_time = 4.0
 strip.tabs._advance()
 check(strip.tabs.stretch == 0, 'The strip springs back after release')
 await process_frame
 center = close.get_global_rect().get_center()
 var outside := center - Vector2(close.size.x, 0)
 close_mouse_button(center, true)
 close_mouse_button(outside, false)
 check(host.closed_ids.is_empty(), 'Release outside cancels even without an intervening motion event')
 for release_position in [outside, center]:
  close_mouse_button(center, true)
  check(host.closed_ids.is_empty(), 'Pressing the close icon waits for release')
  for point in [outside, release_position]:
   var drag := InputEventMouseMotion.new()
   drag.position = point
   drag.button_mask = MOUSE_BUTTON_MASK_LEFT
   root.push_input(drag, true)
  close_mouse_button(release_position, false)
  check(host.closed_ids.is_empty(), 'Dragging off the close icon cancels the press')
 close_mouse_button(center, true)
 close_mouse_button(center, false)
 check(host.closed_ids == [1], 'Close icon targets the selected tab exactly once')
 print('TAB_OVERFLOW failures=',failures)
 quit(1 if failures else 0)

func close_mouse_button(point: Vector2, pressed: bool):
 var click := InputEventMouseButton.new()
 click.position = point
 click.button_index = MOUSE_BUTTON_LEFT
 click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
 click.pressed = pressed
 root.push_input(click, true)
