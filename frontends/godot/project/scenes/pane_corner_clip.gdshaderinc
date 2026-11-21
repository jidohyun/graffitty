// Cuts pane content to its pane's rounded rectangle inside the content's own
// shader.
//
// A canvas group per pane did this offscreen; on tile-based mobile GPUs each
// group stored and reloaded the whole workspace canvas every frame.
//
// Set by WorkspacePane: its size, corner radius, and this item's origin in
// it.
uniform vec2 pane_size = vec2(0.0);
uniform vec2 pane_offset = vec2(0.0);
uniform float pane_radius = 0.0;
varying vec2 pane_position;

float pane_corner_coverage() {
	if (pane_radius <= 0.0 || pane_size.x <= 0.0) { return 1.0; }
	vec2 half_size = pane_size * 0.5;
	vec2 corner = abs(pane_position - half_size) - (half_size - vec2(pane_radius));
	float distance = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - pane_radius;
	// One screen pixel of antialiasing at any canvas zoom.
	return clamp(0.5 - distance / max(fwidth(distance), 0.0001), 0.0, 1.0);
}
