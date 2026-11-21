shader_type canvas_item;
render_mode unshaded;

// Paint only the frame surrounding the active tab. Its open bottom reveals
// the same live world as the content below, without sampling a second texture.
uniform vec2 bar_size = vec2(1.0);
uniform vec4 active_rect = vec4(0.0);
uniform vec2 visible_x = vec2(0.0);
uniform vec4 frame_color : source_color = vec4(0.125, 0.141, 0.173, 1.0);
uniform float top_radius = 12.0;
uniform float foot_radius = 10.0;

float box_distance(vec2 p, vec2 half_size) {
	vec2 q = abs(p) - half_size;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

void fragment() {
	vec2 at = UV * bar_size;
	float coverage = 1.0;
	if (active_rect.z > 0.0 && at.x >= visible_x.x && at.x <= visible_x.y) {
		vec2 p = at - active_rect.xy;
		vec2 size = active_rect.zw;
		float radius = min(top_radius, min(size.x, size.y) * 0.5);
		// Only the top corners are rounded; the bottom opens into the world.
		float r = p.y < size.y * 0.5 ? radius : 0.0;
		float shape = box_distance(p - size * 0.5, size * 0.5 - vec2(r)) - r;
		float foot = min(foot_radius, size.y * 0.5);
		vec2 left = vec2(-foot, size.y - foot);
		vec2 right = vec2(size.x + foot, size.y - foot);
		// Outside quarter-circles form the outward-curving feet at the base.
		// Continue the feet below the strip too, avoiding an antialiased seam
		// against the world's first row at fractional display scales.
		float left_foot = max(box_distance(p - (left + vec2(foot * 0.5, foot)), vec2(foot * 0.5, foot)), foot - length(p - left));
		float right_foot = max(box_distance(p - (right + vec2(-foot * 0.5, foot)), vec2(foot * 0.5, foot)), foot - length(p - right));
		shape = min(shape, min(left_foot, right_foot));
		// Do not antialias a horizontal bottom edge: the opening continues below.
		if (p.y > size.y - 1.0 && p.x >= 0.0 && p.x <= size.x) {
			shape = min(shape, -1.0);
		}
		float aa = max(fwidth(shape) * 0.5, 0.001);
		coverage = smoothstep(-aa, aa, shape);
	}
	COLOR = vec4(frame_color.rgb, frame_color.a * coverage);
}
