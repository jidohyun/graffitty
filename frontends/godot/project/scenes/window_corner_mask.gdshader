shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform float radius_px;

void fragment() {
	vec2 edge_px = min(SCREEN_UV, 1.0 - SCREEN_UV) / SCREEN_PIXEL_SIZE;
	float distance_px = length(max(vec2(radius_px) - edge_px, vec2(0.0)));
	float coverage = clamp(radius_px + 0.5 - distance_px, 0.0, 1.0);
	COLOR = vec4(coverage);
}
