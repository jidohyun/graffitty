extends "res://tests/unit/test_case.gd"
const World := preload("res://scenes/TerminalWorld.gd")
const Motion := preload("res://scenes/CameraMotion.gd")

class NavigationView extends Control:
	var navigation_zoom := 0.8
	var navigation_center := Vector2(1200, 700)
	func uses_navigation_camera() -> bool: return true
	func main_frame() -> Dictionary: return {"zoom": 1.0, "center": Vector2(800, 500)}
	## The whole sheet is usable: no chrome or docks in this fixture.
	func workspace_region() -> RefCounted:
		var region := preload("res://scenes/WorkspaceRegion.gd").new()
		region.configure(Vector2(1600, 1000), Vector4.ZERO)
		return region

class Host extends Node:
	var active_session_id := -1
	var workspace_view: Control

class NavigationWorld extends World:
	var cursor := Vector2(1000, 550)
	func _sheet_size() -> Vector2: return Vector2(1600, 1000)
	func _camera_cursor_uv() -> Vector2: return cursor / _sheet_size()
	func _saddle_uv(uv: Vector2, _inverse := false) -> Vector2: return uv


func test_saved_navigation_applies_typing_tilt_and_returns_to_rest() -> void:
	var host := Host.new()
	var view := NavigationView.new()
	host.workspace_view = view
	var world := NavigationWorld.new()
	world.host = host
	world.fx_cfg = preload("res://scenes/Effects.gd").new()
	world.fx_cfg.set_option("state.typing", "camera.tilt_limit_deg", 12.0)
	world.uv_origin = Vector3(-8, 5, -20)
	world.uv_du = Vector3(16, 0, 0)
	world.uv_dv = Vector3(0, -10, 0)
	world.fx_camera.follow_rect = Rect2(900, 450, 600, 500)
	var base := Motion.pose(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, Vector4(-0.4, -0.25, 0.8, 0.5))
	for zoom in [0.5, 0.8, 1.5]:
		view.navigation_zoom = zoom
		world.navigation_camera_active = false
		for frame in 180:
			world.fx_camera.advance(1.0 / 60.0, world.cursor, world._sheet_size(), Vector2.ONE, 1, 0, 0, 0, true, .35)
			world._advance_navigation_camera(1.0 / 60.0, world.fx_cfg.frame("typing"), true, 0.35)
			world._camera_fx_frame(base)
		expect(world.navigation_camera.tilt.length() > 0.01, "Typing produces tilt in a saved %.1fx view" % zoom)
		var tilted: Dictionary = world._camera_fx_frame(base)
		expect(not tilted.transform.basis.is_equal_approx(base.transform.basis), "Navigation projection applies the controller's tilt")
		expect(view.navigation_center == Vector2(1200, 700) and view.navigation_zoom == zoom, "Typing preserves saved navigation")
		for frame in 1800:
			world.fx_camera.advance(1.0 / 60.0, world.cursor, world._sheet_size(), Vector2.ONE, 1, 0, 0, 0, false, .35)
			world._advance_navigation_camera(1.0 / 60.0, world.fx_cfg.frame("idle"), false, 0.35)
			world._camera_fx_frame(base)
		expect(world.navigation_camera.tilt.length() < 0.0001, "Idle eases navigation tilt to zero")
		var resting: Dictionary = world._camera_fx_frame(base)
		expect(resting.transform.basis.is_equal_approx(base.transform.basis), "Idle restores the untilted saved view")
	world.fx_enabled = false
	world._advance_navigation_camera(1.0 / 60.0, world.fx_cfg.frame("typing"), true, 0.35)
	expect(not world.navigation_camera_active, "Disabling effects disables navigation tilt")
	world.fx_camera.free()
	world.free()
	view.free()
	host.free()
