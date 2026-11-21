extends SceneTree

class LayerPane extends Control:
	var video_layer := false
	func video_layer_geometry(_texels: Transform2D) -> Dictionary:
		return {"index": get_index()} if visible else {}
	func set_video_layer(value: bool) -> bool:
		var changed := value != video_layer
		video_layer = value
		return changed

class LayerWorld extends Node:
	var order := []
	func set_video_layers(layers: Array) -> int:
		order = layers.map(func(layer): return layer.index)
		return mini(2, order.size())

class LayerHost extends Node:
	var presentation_active := true
	var world := LayerWorld.new()

var failures := 0
func expect(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var existing_nodes := Node.get_orphan_node_ids()
	var view := preload("res://scenes/WorkspaceView.gd").new()
	var host := LayerHost.new()
	view.host = host
	root.add_child(view.canvas)
	var parent := Control.new()
	for index in 3:
		var pane := LayerPane.new()
		parent.add_child(pane)
		view.panes[index] = pane
	view.panes[0].z_index = 1
	view._sync_video_layers()
	expect(host.world.order == [0, 2, 1], "Pages are offered by z-index then sibling order")
	expect(view.panes[0].video_layer and view.panes[2].video_layer and not view.panes[1].video_layer, "Overflow pages draw normally")
	view.panes[0].hide()
	view._sync_video_layers()
	expect(not view.panes[0].video_layer and view.panes[1].video_layer, "Hiding a page releases its slot for another page")
	host.presentation_active = false
	view._sync_video_layers()
	expect(not view.panes[1].video_layer and not view.panes[2].video_layer, "Leaving layered presentation restores pane rendering")
	parent.free()
	view.canvas.free()
	host.world.free()
	host.free()
	view.free()
	# The partial workspace fixture never enters _ready to parent its controls.
	for id in Node.get_orphan_node_ids():
		if id in existing_nodes or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	print("Video layer selection failures: ", failures)
	quit(1 if failures else 0)
