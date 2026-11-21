extends "res://tests/unit/test_case.gd"
const Slide := preload("res://scenes/remote/RemoteSwipe.gd")
const Layers := preload("res://scenes/WorkspaceLayers.gd")

class Manager extends Control:
	var saved := 0
	func _remember_view() -> void: saved += 1

func test_workspace_composition_order() -> void:
	expect(Layers.Order.DOCK < Layers.Order.TRANSITION, "Outgoing desktop covers all incoming desktop surfaces")
	expect(Layers.Order.TRANSITION < Layers.Order.MENU, "Menus remain above desktop transitions")
	expect(Layers.Order.DOCK < Layers.Order.MENU and Layers.Order.MENU < Layers.Order.FLOATING_CONTROLS, "Sidebar never covers menu or floating controls")
	expect(Layers.Order.COMMAND < Layers.Order.NOTIFICATION and Layers.Order.NOTIFICATION < Layers.Order.FLOATING_CONTROLS, "Floating controls sit above command line and notifications")
	expect(Layers.Order.FLOATING_CONTROLS > 1024, "Floating controls draw above Godot's embedded-window canvas (layer 1024)")

func test_slide_tracks_finger_and_cleans_up() -> void:
	var manager := Manager.new()
	var layer := Control.new()
	manager.add_child(layer)
	layer.size = Vector2(400, 600)
	layer.position = Vector2(12, 20)
	var snapshot := TextureRect.new()
	manager.add_child(snapshot)
	var slide := Slide.new()
	slide.manager = manager
	slide._root = layer
	slide._origin = layer.position
	slide._snapshot = snapshot
	slide._layers = Layers.new()
	manager.add_child(slide._layers)
	var dock: CanvasLayer = slide._layers.create_layer(Layers.Order.DOCK, true)
	var controls: CanvasLayer = slide._layers.create_layer(Layers.Order.FLOATING_CONTROLS)
	slide._active = true
	slide._direction = 1
	slide._apply(-.25)
	expect(layer.position.x == 312 and snapshot.position.x == -88, "Incoming and outgoing desktops track the same finger displacement")
	expect(dock.offset.x == 300 and controls.offset == Vector2.ZERO, "Sidebar belongs to the sliding desktop; floating controls remain stationary")
	slide._apply(.2)
	expect(slide._progress == 0, "Reversal beyond the origin cannot expose an unrelated desktop")
	slide._finish(true)
	expect(layer.position == Vector2(12, 20) and not slide._active, "Settling resets the live workspace transform")
	expect(slide._snapshot == null and manager.saved == 1, "Settling releases the snapshot and saves the view")
	expect(dock.offset == Vector2.ZERO, "Settling resets every registered desktop surface")
	slide.free()
	manager.free()

func test_edge_resists_and_cancel_restores() -> void:
	var manager := Manager.new()
	var layer := Control.new()
	manager.add_child(layer)
	layer.size = Vector2(400, 600)
	var slide := Slide.new()
	slide.manager = manager
	slide._root = layer
	slide._layers = Layers.new()
	manager.add_child(slide._layers)
	slide._active = true
	slide._direction = -1
	slide._apply(.8)
	expect(layer.position.x > 0 and layer.position.x < 40, "End-of-list resistance is bounded without wrapping")
	slide.cancel()
	expect(layer.position == Vector2.ZERO and not slide._active, "Cancellation resets resisted displacement")
	slide.free()
	manager.free()
