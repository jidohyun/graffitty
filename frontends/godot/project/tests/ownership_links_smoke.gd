extends SceneTree
## Ownership is retained in data, but explicit graph wires replace its paint.
const Links := preload("res://scenes/WorkspaceChromiumLinks.gd")
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func run() -> void:
	var links := Links.new()
	root.add_child(links)
	var rectangles := {"%1": Rect2(0, 0, 100, 100), "%2": Rect2(200, 0, 100, 100), "%3": Rect2(200, 200, 100, 100)}
	var owners := {"%2": "%1", "%3": "%1"}
	links.sync(rectangles, owners)
	check(links.edges.size() == 2, "All spawned panes show ownership without explicit edges")
	for i in 4: await process_frame
	var draws: int = links.wire_layer.draw_count
	links.sync(rectangles, owners, func(p): return p * 2 + Vector2(10, 20))
	for i in 4: await process_frame
	check(links.wire_layer.draw_count == draws, "Camera movement does not repaint ownership wires")
	var wire_draws: int = links.wire_layer.wire_draw_count()
	rectangles["%2"].position += Vector2(10, 5)
	links.sync(rectangles, owners)
	for i in 4: await process_frame
	check(links.wire_layer.wire_draw_count() - wire_draws == 1, "Moving a child repaints only its ownership wire")
	for edge in [{"from": "%1", "to": "%2"}, {"from": "%2", "to": "%1"}, {"from": "%1", "to": "%2", "muted": true}]:
		links.sync(rectangles, owners, Callable(), {}, [edge])
		check(links.edges.size() == 1 and not links.routes.has("%2"), "Explicit edge replaces ownership paint in either direction, including muted edges")
	check(owners == {"%2": "%1", "%3": "%1"}, "Spawn ownership metadata is unchanged")
	links.sync(rectangles, owners)
	check(links.edges.size() == 2, "Removing the graph connection restores ownership paint")
	links.queue_free()
	await process_frame
	quit(1 if failures else 0)
