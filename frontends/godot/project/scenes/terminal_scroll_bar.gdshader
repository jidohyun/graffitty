shader_type canvas_item;
// macOS-style overlay scroller on one quad: a translucent capsule thumb with a
// hairline edge, and a track that appears only under the pointer. No textures,
// no screen reads.
uniform vec2 extent = vec2(8.0, 100.0);
// Thumb start and length along the bar, in local pixels.
uniform vec2 thumb = vec2(0.0, 40.0);
// 0 at rest, 1 under the pointer or while dragging (eased by the script).
uniform float hover = 0.0;
uniform float pressed = 0.0;

varying vec2 local;

void vertex() {
	local = VERTEX;
}

float capsule(vec2 p, float top, float bottom, float radius) {
	float cx = extent.x * 0.5;
	vec2 axis = vec2(cx, clamp(p.y, top + radius, max(top + radius, bottom - radius)));
	return length(p - axis) - radius;
}

// Straight-alpha "over".
vec4 over(vec4 top, vec4 under) {
	float a = top.a + under.a * (1.0 - top.a);
	return vec4((top.rgb * top.a + under.rgb * under.a * (1.0 - top.a)) / max(a, 1e-4), a);
}

void fragment() {
	vec2 p = local;
	float aa = 0.5 * max(fwidth(p.y), 0.5);
	vec4 color = vec4(0.0);

	// Track: a faint full-height tint with a hairline on its leading edge.
	float track = hover * 0.06;
	float hairline = hover * 0.10 * (1.0 - smoothstep(0.0, 1.0, p.x));
	color = vec4(vec3(1.0), track + hairline);

	// Thumb: slimmer at rest, full width under the pointer.
	float radius = mix(extent.x * 0.5 - 1.5, extent.x * 0.5 - 0.5, hover);
	float d = capsule(p, thumb.x + 1.0, thumb.x + thumb.y - 1.0, radius);
	float fill = 1.0 - smoothstep(-aa, aa, d);
	// A dark hairline just outside keeps it legible on light content.
	float rim = (1.0 - smoothstep(-aa, aa, d - 1.0)) - fill;
	float a = mix(0.55, 0.72, hover) + 0.14 * pressed;
	color = over(vec4(vec3(0.0), rim * 0.18), color);
	color = over(vec4(vec3(0.62), fill * a), color);
	COLOR = color;
}
