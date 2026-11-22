extends SceneTree
## An unchanged reconcile must not redraw the strip: every strip redraw makes the
## whole window draw another frame while terminal output refreshes the tabs.
var failures := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-tab-redraw-%d" % OS.get_process_id()))
	run.call_deferred()

func frames(count: int) -> void:
	for i in count:
		await process_frame

func run() -> void:
	root.size = Vector2i(700, 240)
	var strip := preload("res://scenes/TabStrip.gd").new()
	strip.size = Vector2(650, 44)
	root.add_child(strip)
	var pages := [{"id": 1, "title": "First"}, {"id": 2, "title": "Second"}]
	strip.reconcile(pages, 1)
	await frames(30)
	var draws := [0]
	strip.draw.connect(func(): draws[0] += 1)
	strip.reconcile(pages, 1)
	await frames(5)
	check(draws[0] == 0, "Reconciling unchanged tabs does not redraw the strip (%d draws)" % draws[0])
	strip.set_external_drop_hint(1, "Incoming")
	await frames(3)
	check(draws[0] > 0, "Showing the external drop line redraws the strip")
	strip.free()
	quit.call_deferred(failures)
