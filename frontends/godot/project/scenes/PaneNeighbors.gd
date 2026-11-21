extends RefCounted
## Shared Rust policy; layout coordinates are independent of camera animation.
static func find(rects: Dictionary, source: String, direction: String, algorithm := "weighted") -> String:
	# The native ABI takes an untyped dictionary; copying strips the runtime
	# Dictionary[String, Rect2] tag used by WorkspaceView without losing values.
	var values := {}
	values.merge(rects)
	return preload("res://scenes/WorkspaceLayout.gd")._core().navigation_neighbor(values, source, direction, algorithm)
