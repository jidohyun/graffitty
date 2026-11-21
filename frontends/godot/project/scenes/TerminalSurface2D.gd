extends Node2D
## Lightweight session place: no mesh, collision, or per-tab camera.
@export var session_id := -1
@export var surface_id := ""
var id: String:
	get: return surface_id
