extends SceneTree
## A long press on a mod panel row opens its context menu (a right click) when
## the finger lifts where it rested; held and dragged, it stays a left
## press-and-drag (Sessions reordering), and a quick tap still clicks.
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)


func _initialize() -> void:
	run.call_deferred()


func touch(view: Control, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = at
	event.pressed = pressed
	root.push_input(event, true)
	await process_frame


func drag(at: Vector2, relative: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = at
	event.relative = relative
	root.push_input(event, true)
	await process_frame


func names(host: RefCounted) -> Array:
	return host.take_requests().filter(func(request): return request.kind == "run").map(func(request): return str(request.name))


func run() -> void:
	root.size = Vector2i(400, 300)
	var host: RefCounted = ClassDB.instantiate("ModHost")
	check(host.setup("").is_empty(), "Mod host starts")
	var view: Control = ClassDB.instantiate("ModView")
	root.add_child(view)
	view.position = Vector2(20, 20)
	view.size = Vector2(300, 200)
	check(view.load_source("long-press-fixture", """
import { View, div } from 'graffitty-ui';
import { run } from 'graffitty';
export default class extends View {
  render() {
    return div().size_full().bg('#334')
      .on_mouse_down('right', () => run('Menu', {}))
      .on_mouse_down('left', () => run('Press', {}))
      .on_click(() => run('Click', {}));
  }
}
""", '{}').is_empty(), "Fixture loads")
	view.render_now()
	await process_frame
	names(host)
	var at := Vector2(120, 100)
	await touch(view, at, true)
	await touch(view, at, false)
	check(names(host).has("Click"), "A quick tap clicks")
	await touch(view, at, true)
	await create_timer(0.6).timeout
	var held := names(host)
	check(held.has("Press") and not held.has("Menu"), "A held finger presses, ready to drag: %s" % [held])
	await touch(view, at, false)
	var lifted := names(host)
	check(lifted.has("Menu") and not lifted.has("Click"), "Lifting a long press where it rested opens the menu, without a click: %s" % [lifted])
	await touch(view, at, true)
	await create_timer(0.6).timeout
	names(host)
	await drag(at + Vector2(0, 30), Vector2(0, 30))
	await touch(view, at + Vector2(0, 30), false)
	var dragged := names(host)
	check(not dragged.has("Menu"), "A held finger that drags stays a press-and-drag: %s" % [dragged])
	print("MOD_LONG_PRESS_PASS" if failures.is_empty() else "MOD_LONG_PRESS_FAIL")
	quit(0 if failures.is_empty() else 1)
