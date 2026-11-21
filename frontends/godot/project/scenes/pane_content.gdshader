shader_type canvas_item;
// Pane content that reaches the pane's corners, such as a Chromium page.
// COLOR already holds the sampled texture; only its coverage changes.
#include "res://scenes/pane_corner_clip.gdshaderinc"

void vertex() {
	pane_position = VERTEX + pane_offset;
}

void fragment() {
	COLOR.a *= pane_corner_coverage();
}
