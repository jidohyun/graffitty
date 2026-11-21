# Shared camera motion

Use `scenes/CameraMotion.gd` for camera flights instead of a separate controller.
It returns a transform and frustum without owning a world or scene tree.

## Start a flight

`scenes/CameraMotion.gd` is a RefCounted component with no dependency on a world,
terminal, scene tree or configuration class. It produces a complete camera frame:
`{transform: Transform3D, rect: Vector4(left, bottom, width, height)}`. Frustum
values are tangents at unit depth, using the renderer's width convention.

```gdscript
const Motion = preload("res://scenes/CameraMotion.gd")
var motion = Motion.new()

# Initialize from the view the user actually sees.
motion.reset(Motion.pose(camera.global_position, -camera.global_basis.z,
    camera.global_basis.y, Vector4(-0.5, -0.3, 1.0, 0.6)))

# Retarget without resetting: current pose, lens and velocity are preserved.
var target = Motion.pose(destination, forward, up, framing)
motion.retarget(target, 1.2, optional_route_points)

# In your process callback:
Motion.apply(camera, motion.advance(delta))
```

## Keep flights continuous

- Initialize from the displayed frame, not an old destination.
- Retarget without calling `reset()` to retain pose, lens, and velocity.
- Apply the returned frame to both scenery and ink cameras.
- Supply routes with obstacle clearance; this component does no collision detection.

For interactive framing, route reversal, resizing, and interpolation math,
see [Camera motion reference](camera-motion-reference.md).
