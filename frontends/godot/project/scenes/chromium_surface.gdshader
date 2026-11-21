shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled, fog_disabled;
uniform sampler2D chromium_tex : source_color, filter_linear;
uniform sampler2D chrome_tex : source_color, filter_linear;
uniform float chrome_fraction = 0.12;
uniform bool page_ready = true;
uniform vec2 surface_size = vec2(1.6, 1.0);
uniform float opacity = 1.0;
uniform float exposure_compensation = 1.0;
uniform float scatter = 0.0;
void vertex() {
	// All vertices of a toolbar tile receive the same displacement. The page
	// is one intact quad (COLOR.a == 0), never subdivided or distorted.
	float p = scatter * scatter * COLOR.a;
	float seed = fract(sin(dot(COLOR.rg, vec2(127.1, 311.7))) * 43758.5453);
	VERTEX += vec3((COLOR.r - 0.5) * surface_size.x * 0.32,
		(0.4 + seed * 0.6) * surface_size.y * 0.16,
		seed * min(surface_size.x, surface_size.y) * 0.16) * p;
}
void fragment() {
	// Rounded, softly antialiased silhouette; no full-height panel or divider.
	float radius = min(surface_size.x, surface_size.y) * 0.025;
	vec2 q = abs((UV - 0.5) * surface_size) - surface_size * 0.5 + radius;
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float edge = max(fwidth(d), min(surface_size.x, surface_size.y) * 0.002);
	vec4 page;
	if (UV.y < chrome_fraction) {
		page = texture(chrome_tex, vec2(UV.x, UV.y / chrome_fraction));
	} else {
		page = page_ready ? texture(chromium_tex, vec2(UV.x, (UV.y - chrome_fraction) / (1.0 - chrome_fraction))) : vec4(0.012, 0.018, 0.028, 1.0);
	}
	ALBEDO = page.rgb / max(exposure_compensation, 0.0001);
	ALPHA = page.a * opacity * (1.0 - smoothstep(-edge, edge, d));
}
