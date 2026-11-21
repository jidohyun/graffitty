extends SceneTree

class Host extends Node:
	var workspace_view := Control.new()

class World extends "res://scenes/TerminalWorld.gd":
	func _window_render_size() -> Vector2:
		return Vector2(2400, 1500)

func _initialize() -> void:
	var world := World.new()
	var host := Host.new()
	world.host = host
	# The sheet excludes the 42-pixel tab strip; the camera renders the full frame.
	world.uv_origin = Vector3(-1.2, .729, -2)
	world.uv_du = Vector3(2.4, 0, 0)
	world.uv_dv = Vector3(0, -1.458, 0)
	var frame: Dictionary = world._camera_base_frame(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, .6)
	var rect: Vector4 = frame.rect
	var valid := is_equal_approx(rect.z / rect.w, 1.6) and is_zero_approx(rect.y + rect.w * .5)
	print("WORKSPACE_CAMERA_ASPECT_PASS" if valid else "WORKSPACE_CAMERA_ASPECT_FAIL: " + str(rect))
	host.workspace_view.free()
	world.host = null
	world.fx_camera.free()
	world.free()
	host.free()
	quit(0 if valid else 1)
