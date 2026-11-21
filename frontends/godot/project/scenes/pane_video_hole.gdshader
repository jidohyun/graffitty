shader_type canvas_item;
// A Chromium page that the world composites beneath the workspace canvas
// (TerminalWorld.set_video_layers).
//
// Its pane erases the canvas under the page instead of drawing it, so a new
// page frame redraws the world but not the canvas.
//
// Multiplying by the uncovered area keeps the antialiased corners of
// pane_content.gdshader; content drawn later, such as overlays, stays on top.
render_mode unshaded, blend_mul;
#include "res://scenes/pane_corner_clip.gdshaderinc"

void vertex() {
	pane_position = VERTEX + pane_offset;
}

void fragment() {
	COLOR = vec4(1.0 - pane_corner_coverage());
}
