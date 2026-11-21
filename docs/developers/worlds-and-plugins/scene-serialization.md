# Generate a Godot scene

Use these rules only when generating `.tscn` files from code. The editor handles serialization for ordinary authored scenes.

## Appendix: writing a `.tscn` from a script

Two rules prevent rotated screens and incorrect camera poses:

1. Serialize `Transform3D` bases row-major:

   ```gdscript
   var_to_str(Transform3D(Vector3(1,2,3), Vector3(4,5,6), Vector3(7,8,9), Vector3(10,11,12)))
   # Transform3D(1, 4, 7, 2, 5, 8, 3, 6, 9, 10, 11, 12)
   ```

2. Convert world-space child poses through the parent's inverse before saving
   their local `transform`.

Compare generated corners, poses, field of view, and sizes with the source data.
