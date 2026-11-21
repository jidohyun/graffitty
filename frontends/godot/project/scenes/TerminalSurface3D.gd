@tool
class_name TerminalSurface3D
extends MeshInstance3D
## A terminal's screen, placed in the world by hand.
##
## This is the node a world author drags around. One per destination: a
## rectangle the terminal is drawn on, plus the camera pose the world flies to
## when that destination is selected. The kit reads both off the scene tree, so
## a world is authored in the editor and not in a sidecar file.
##
##     LiveTerminalWall0        TerminalSurface3D   <- move and rotate this
##     └─ ViewPose              Camera3D            <- and this
##
## The `ViewPose` child is an ordinary [Camera3D]. That is deliberate: the
## editor already draws a frustum gizmo for it, its Preview button already shows
## exactly what the flight will land on, and `fov` is already the right number.
## The kit reads `fov` under [constant Camera3D.KEEP_WIDTH], so it is the
## **horizontal** angle.
##
## The mesh is generated from [member canvas] and is never hand-edited. A flat
## quad is all the geometry a terminal needs: `terminal_sheet.gdshader` does its
## curvature, ripple and splash per fragment, and its `vertex()` only carries
## depth. Tessellating the screen buys nothing.

## Name the rest of the world knows this surface by.
##
## Empty means the node's own name, which is what you want unless the node
## gets renamed for the outline's sake and the id has to stay stable.
@export var surface_id: String = "":
	set(value):
		surface_id = value
		update_configuration_warnings()

## Where this destination sits in the tab order.
##
## Ties break by tree order, so leaving every surface at 0 and dragging them
## into order in the scene dock is a valid way to lay out a world.
@export var visit_order: int = 0

## The screen's size in world units. The terminal's texture is fitted to this
## rectangle's aspect, so it also decides whether the shell looks wide or
## tall.
##
## Editing it rebuilds the quad live in the editor.
@export var canvas := Vector2(16.0, 10.0):
	set(value):
		canvas = Vector2(maxf(value.x, 0.01), maxf(value.y, 0.01))
		_rebuild_mesh()

## Offset the screen mesh along its normal to prevent z-fighting
## with coplanar geometry.
##
## Keep the offset in the mesh. The node position remains the authored
## plane when moved in the editor.
@export var surface_lift := 0.06:
	set(value):
		surface_lift = value
		_rebuild_mesh()


## Which host session draws here. Assigned by the kit when the world is bound
## to a host, never authored: a scene has no idea what tabs exist yet.
var session_id := -1

## The id the kit keys `walls` and `focus_points` by.
var id: String:
	get:
		return surface_id if not surface_id.is_empty() else String(name)

## The camera pose this destination is viewed from. A missing one is an
## authoring error, reported by [method _get_configuration_warnings]; the
## fallbacks below only keep a half-built scene from taking the host down.
var view_pose: Camera3D:
	get:
		for child in get_children():
			if child is Camera3D:
				return child
		return null

var eye: Vector3:
	get:
		var pose := view_pose
		return pose.global_position if pose != null else global_position + global_basis.z * 10.0

## Points from the viewing pose into the screen, so its inverse is the
## viewer-facing normal.
var forward: Vector3:
	get:
		var pose := view_pose
		return -(pose.global_basis.z if pose != null else global_basis.z).normalized()

var up: Vector3:
	get:
		var pose := view_pose
		return pose.global_basis.y.normalized() if pose != null else Vector3.UP

## Tangent of half the horizontal field of view — the form the camera rig and
## the flight interpolation both want, and the form the KWALL `halfX` was in.
var half_x: float:
	get:
		var pose := view_pose
		return tan(deg_to_rad(pose.fov if pose != null else 47.9) * 0.5)


func _init() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _ready() -> void:
	_rebuild_mesh()


## Where the terminal's uv (0,0) corner lands in world space, and the two edge
## vectors leading away from it.
##
## Under the old triangle-soup surfaces this had to be least-squares fitted
## out of 2400 vertices on every tab change; a quad with a transform simply
## knows.
##
## The lift is excluded: this is the authored plane. Rendered effects add
## surface_lift so their geometry meets the visible terminal mesh exactly.
func uv_basis() -> Dictionary:
	var half := canvas * 0.5
	return {
		"origin": global_transform * Vector3(-half.x, half.y, 0.0),
		"du": global_basis * Vector3(canvas.x, 0.0, 0.0),
		"dv": global_basis * Vector3(0.0, -canvas.y, 0.0),
	}


## Filament's `focusPoint()`: the mean depth of the screen along the view
## direction, measured from the eye.
##
## For a flat quad that is its centre projected onto the view axis, so the
## 2400-vertex mean the old path computed collapses to one dot product with
## the same answer.
func focus_point() -> Vector3:
	var origin := eye
	var direction := forward
	return origin + direction * maxf((global_position - origin).dot(direction), 0.1)


func _rebuild_mesh() -> void:
	remove_meta("render_region")
	var quad := mesh as QuadMesh
	if quad == null:
		quad = QuadMesh.new()
		mesh = quad
	quad.size = canvas
	quad.center_offset = Vector3(0.0, 0.0, surface_lift)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if view_pose == null:
		warnings.append(
			"No Camera3D child. Add one named ViewPose: it is the "
			+ "pose the world flies to for this surface, and its fov is the "
			+ "horizontal field of view the flight lands on."
		)
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != self and sibling is TerminalSurface3D and sibling.id == id:
				warnings.append("Another surface already uses the id \"%s\"." % id)
				break
	return warnings


## Extend only the display geometry. The authored canvas, camera and UV basis
## continue to define the main area; out-of-frame windows share its plane.
func set_render_region(region: Rect2) -> void:
	if get_meta("render_region", Rect2()) == region:
		return
	set_meta("render_region", region)
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	for uv in [
		region.position,
		Vector2(region.position.x, region.end.y),
		region.end,
		Vector2(region.end.x, region.position.y),
	]:
		vertices.append(Vector3((uv.x - 0.5) * canvas.x, (0.5 - uv.y) * canvas.y, surface_lift))
		uvs.append(uv)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(
		[Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK]
	)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var expanded := ArrayMesh.new()
	expanded.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = expanded
