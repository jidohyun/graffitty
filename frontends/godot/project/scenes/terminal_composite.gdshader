shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
// Transparent SubViewport output is premultiplied; composite coverage once.
// Titles stay screen-sized when zoomed out. Dim, rather than erase, covered
// terminal content so the enlarged title area remains translucent.
uniform float content_clip_top = 0.0;
uniform float content_clip_feather = 0.0;
uniform float title_content_alpha : hint_range(0.0, 1.0) = 0.5;
uniform vec4 texture_region = vec4(0.0,0.0,1.0,1.0);
#include "res://scenes/terminal_defocus.gdshaderinc"
// Texture UV -> source sheet UV, before the sheet's saddle/wave projection.
uniform vec4 ink_sheet_rect = vec4(0.0, 0.0, 1.0, 1.0);
// Exact plane camera depth: depth(uv) = x + y * uv.x + z * uv.y.
uniform vec3 ink_depth_plane = vec3(1.0, 0.0, 0.0);
uniform vec2 tex_size = vec2(1.0);
uniform vec4 panel_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float curvature_rad = 0.0;
uniform float ripple = 0.0;
uniform float ripple_wavelength = 0.35;
uniform float ripple_falloff = 0.3;
uniform float ripple_phase = 0.0;
uniform float wave_zoom = 1.0;
uniform vec2 cursor = vec2(0.5);
uniform vec4 splash_rings[8];
uniform int splash_count = 0;
uniform float splash_life = 0.7;
uniform float splash_speed = 600.0;
#include "res://scenes/terminal_sheet_wave.gdshaderinc"
#include "res://scenes/pane_corner_clip.gdshaderinc"

void vertex() {
	pane_position = VERTEX + pane_offset;
}

float ink_view_depth(vec2 source_uv) {
	vec2 centre = panel_rect.xy + panel_rect.zw * 0.5;
	// Forward map of the same wave and saddle inverses in terminal_sheet.
	vec2 displayed = centre + (source_uv - centre) / max(1.0 + sheet_depth(source_uv), 0.001);
	if (abs(curvature_rad) > 0.000001) {
		vec2 size = panel_rect.zw * tex_size;
		float extent = max(size.x, size.y);
		float coefficient = tan(curvature_rad) * 2.5 / max(extent * extent, 0.001);
		float fit = 1.0 / max(1.0 - abs(coefficient * size.x * size.y * 0.25), 0.05);
		vec2 p = (displayed - centre) * tex_size * vec2(1.0, -1.0);
		displayed = centre + p * vec2(1.0, -1.0) / max((1.0 + coefficient * p.x * p.y) * fit, 0.001) / tex_size;
	}
	return dot(ink_depth_plane, vec3(1.0, displayed));
}

void fragment() {
	// Derivatives are undefined after a discard; measure coverage first.
	float coverage = pane_corner_coverage();
	vec2 uv = (UV-texture_region.xy)/texture_region.zw;
	if (any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) { discard; }
	vec4 ink = texture(TEXTURE, uv);
	if (content_clip_top > 0.0) {
		float uncovered = content_clip_feather > 0.0
			? smoothstep(content_clip_top, content_clip_top + content_clip_feather, UV.y)
			: step(content_clip_top, UV.y);
		// Both RGB and alpha must scale for premultiplied-alpha blending.
		ink *= mix(title_content_alpha, 1.0, uncovered);
	}
	if (defocus_weight > 0.0 && defocus_strength > 0.0) {
		float depth = ink_view_depth(ink_sheet_rect.xy + UV * ink_sheet_rect.zw);
		ink.rgb *= terminal_defocus_gain(depth);
	}
	// The PTY viewport has transparent default background. Tint its ink before
	// adding pane backgrounds/chrome; premultiplied antialias coverage is retained.
	COLOR = ink * coverage;
}
