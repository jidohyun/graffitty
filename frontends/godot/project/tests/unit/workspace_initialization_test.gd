extends "res://tests/unit/test_case.gd"

class Host extends Node:
	var session_backend := RefCounted.new()

class View extends "res://scenes/WorkspaceView.gd":
	var frame_reads := 0
	func main_frame() -> Dictionary:
		frame_reads += 1
		return {"center": Vector2(300, 200), "zoom": 0.5}

func test_partial_initialization_does_not_refresh_navigation_or_children() -> void:
	var view := View.new()
	view.host = Host.new()
	# NativeWindowFrame can synchronously request refresh before _ready has
	# attached all workspace controls. Navigation must wait for the complete view.
	view.foreground_clip.add_child(view.foreground_root)
	view.foreground_root.add_child(view.pointer)
	view.refresh()
	expect(view.frame_reads == 0, "Partial initialization must not query layout")
	expect(view.navigation_center == Vector2.ZERO and view.navigation_zoom == 1.0,
		"Reentrant startup refresh leaves navigation unchanged")
	expect(not view._initialized, "Fixture remains only partially initialized")
