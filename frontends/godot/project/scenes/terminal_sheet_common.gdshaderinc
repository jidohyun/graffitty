// Filter the texture on the angled wall. Point sampling can skip or
// double glyph columns even when the glyphs are antialiased.
//
// The texture stores premultiplied coverage so interpolation is valid.
// See the unpremultiplication step in fragment().
uniform sampler2D terminal_tex : filter_linear, source_color;
uniform sampler2D terminal_blur_1 : filter_linear, repeat_disable, source_color;
uniform sampler2D terminal_blur_2 : filter_linear, repeat_disable, source_color;
uniform sampler2D terminal_blur_3 : filter_linear, repeat_disable, source_color;
uniform sampler2D terminal_blur_4 : filter_linear, repeat_disable, source_color;
uniform bool blur_pyramid_ready = false;
uniform vec2 tex_size = vec2(1280.0, 800.0);
uniform vec4 texture_region = vec4(0.0,0.0,1.0,1.0);
uniform float ink_gain = 1.0;
uniform float wall_shade = 0.3;
uniform float exposure_compensation = 1.0;
uniform vec4 panel_color : source_color = vec4(0.0);
uniform float panel_opacity = 0.0;
uniform float focus_depth = 1.0;
uniform float blur_radius = 0.0;
uniform float blur_limit = 24.0;
varying float sheet_view_depth;
varying vec2 sheet_light_range;

#ifdef SHEET_2D
void vertex() {
 sheet_view_depth = 1.0;
 sheet_light_range = vec2(1.0, 0.0);
}
#else
instance uniform float workspace_clip_top = 0.0;
void vertex() {
	sheet_view_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	float centre_depth = -(MODELVIEW_MATRIX * vec4(0.0, 0.0, VERTEX.z, 1.0)).z;
	float deviation = dot(abs(vec2(MODELVIEW_MATRIX[0].z, MODELVIEW_MATRIX[1].z)), abs(VERTEX.xy));
	sheet_light_range = vec2(centre_depth, deviation);
}
#endif

// --- camera (sheet framing) -------------------------------------------------
uniform float zoom = 1.0;              // 1 = rest; typing states raise it
uniform vec2 tilt_rad = vec2(0.0);     // cursor_response, capped at tilt_limit_deg
// The final row of the page homography, over the page's -1..1 NDC.
uniform vec3 homography_row = vec3(0.0, 0.0, 1.0);
uniform float plane_lift_factor = 1.0;
// How much of that lean DEFORMS the page.
//
// The camera path leaves the paper flat and swings the camera instead
// (camera_motion.h: "never animates or transforms sheet geometry"), so this
// is 0 and tilt_rad only lights the page.
//
// 1.0 restores the old sheet-space skew.
uniform float tilt_warp = 0.0;
uniform vec2 pan = vec2(0.0);          // drift + shake, in page-normalised units

// --- sheet shape ------------------------------------------------------------
uniform float curvature_rad = 0.0;     // Saddle depth: z = tan(s)*2.5*x*y/halfmax
uniform float edge_margin = 0.0;       // px of page border
uniform float corner_radius = 0.0;     // px
uniform float edge_blur = 0.0;
uniform vec4 panel_rect = vec4(0.0, 0.0, 1.0, 1.0);
// Where the page lies on the surface, in the mesh's UV. A wall wider or taller
// than the frame keeps its page to the part the camera shows at rest.
uniform vec4 sheet_window = vec4(0.0, 0.0, 1.0, 1.0);
uniform float edge_shadow = 0.0;       // sheet_edge_shadow
uniform float edge_shadow_width = 48.0;
uniform float content_gloss = 0.0;

// --- ripple + splash --------------------------------------------------------
uniform float ripple = 0.0;            // amplitude, per behaviour state
uniform float ripple_wavelength = 0.35;
uniform float ripple_speed = 2.5;
uniform float ripple_falloff = 0.3;
uniform vec2 cursor = vec2(0.5);
uniform vec4 splash = vec4(0.5, 0.5, -1.0, 0.0);  // origin.xy, age (<0 = none), scale
uniform float splash_speed = 600.0;
uniform float splash_life = 0.7;
uniform vec4 splash_rings[8]; // source UV, age, birth amplitude in degrees
uniform int splash_count = 0;
uniform float ripple_phase = 0.0; // radians, not cycles
uniform float wave_zoom = 1.0;
uniform float time_s = 0.0;

// --- tilt lighting ----------------------------------------------------------
uniform float tilt_light_strength = 0.5;
uniform float tilt_light_min = 0.45;
uniform float tilt_light_max = 1.15;
uniform vec3 tilt_light_color : source_color = vec3(1.0, 0.941, 0.863);   // #fff0dc
uniform float shadow_tint_strength = 1.0; // color intensity only; preserves shadow brightness
uniform vec3 tilt_shadow_color : source_color = vec3(0.616, 0.698, 0.839); // #9db2d6

// Rounded-rect signed distance, in page-normalised units.
float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

#include "res://scenes/terminal_sheet_wave.gdshaderinc"
#include "res://scenes/terminal_defocus.gdshaderinc"

uniform bool workspace_canvas = false;

// Chromium pages beneath the workspace canvas, seen through the holes their
// panes cut in it (pane_video_hole.gdshader), so a page frame redraws this
// world but not the canvas.
//
// Rectangles are canvas texels: position, size.
// TerminalWorld.set_video_layers() fills the slots topmost first.
uniform int page_count = 0;
uniform sampler2D page_0 : source_color, filter_linear, repeat_disable;
uniform sampler2D page_1 : source_color, filter_linear, repeat_disable;
uniform sampler2D page_2 : source_color, filter_linear, repeat_disable;
uniform sampler2D page_3 : source_color, filter_linear, repeat_disable;
uniform vec4 page_rect_0;
uniform vec4 page_rect_1;
uniform vec4 page_rect_2;
uniform vec4 page_rect_3;
uniform vec4 page_clip_0;
uniform vec4 page_clip_1;
uniform vec4 page_clip_2;
uniform vec4 page_clip_3;
uniform float page_radius_0;
uniform float page_radius_1;
uniform float page_radius_2;
uniform float page_radius_3;

// The page fills its hole as filtering samples it: the texels whose centres
// lie inside the page quad, cut to the pane's antialiased corners.
//
// Content drawn over the hole leaves less of the canvas uncovered, and
// translucent pane glass beside it none: both bound the page's share.
vec4 page_beneath(vec4 ink, sampler2D page, vec4 rect, vec4 clip, float radius, vec2 texel) {
	vec2 first = ceil(rect.xy - 0.5);
	vec2 end = ceil(rect.xy + rect.zw - 0.5);
	vec2 inside = clamp(texel - first + 0.5, 0.0, 1.0) * clamp(end + 0.5 - texel, 0.0, 1.0);
	float hole = inside.x * inside.y;
	if (hole <= 0.0) { return ink; }
	if (radius > 0.0) {
		vec2 half_size = clip.zw * 0.5;
		hole *= clamp(0.5 - rounded_box(texel - clip.xy - half_size, half_size, min(radius, min(half_size.x, half_size.y))), 0.0, 1.0);
	}
	vec4 color = texture(page, (texel - rect.xy) / rect.zw);
	float share = min(hole, 1.0 - ink.a) * color.a;
	return vec4(ink.rgb + color.rgb * share, ink.a + share);
}

void fragment() {
	bool clipped = false;
#ifndef SHEET_2D
	clipped = SCREEN_UV.y < workspace_clip_top;
#endif
#ifdef SHEET_2D
 vec2 sheet_uv = texture_region.xy + UV * texture_region.zw;
#else
 vec2 sheet_uv = UV;
#endif
	vec2 texel = 1.0 / tex_size;

	// Page rect: edge_margin insets the content, leaving a border like paper.
	vec2 margin = vec2(edge_margin) * texel;
	vec2 page_lo = margin;
	vec2 page_hi = vec2(1.0) - margin;
	vec2 span = max(page_hi - page_lo, vec2(1e-4));
	vec2 page = ((sheet_uv - sheet_window.xy) / sheet_window.zw - page_lo) / span; // 0..1 across the page
	vec2 p = page * 2.0 - 1.0;                  // -1..1, sheet space
	vec2 page_p = p;                            // undeformed, for the page mask
	float homography_w = dot(vec3(p, 1.0), homography_row);
	p /= max(homography_w, 0.2);
	p /= max(plane_lift_factor, 0.001);

	// Inverse perspective of the depth field around the actual panel centre.
	vec2 centre = panel_rect.xy + panel_rect.zw * 0.5;
	vec2 displayed_uv = p * 0.5 + 0.5;
	if (abs(curvature_rad) > 0.000001) {
		vec2 size = panel_rect.zw * tex_size;
		float extent = max(size.x, size.y);
		// paper_z / (2*max(width,height)), with source pixels and Y upward.
		float coefficient = tan(curvature_rad) * 2.5 / max(extent * extent, 0.001);
		float corner_depth = abs(coefficient * size.x * size.y * 0.25);
		float fit = 1.0 / max(1.0 - corner_depth, 0.05);
		vec2 q = (displayed_uv - centre) * tex_size * vec2(1.0, -1.0) * fit;
		float discriminant = 1.0 - 4.0 * coefficient * q.x * q.y;
		clipped = clipped || discriminant < 0.0;
		float t = 2.0 / (1.0 + sqrt(max(discriminant, 0.0)));
		displayed_uv = centre + q * t * vec2(1.0, -1.0) / tex_size;
	}
	vec2 source_uv = displayed_uv;
	if (ripple > 0.0 || splash_count > 0) {
		for (int iteration = 0; iteration < 4; iteration++) {
			source_uv = centre + (displayed_uv - centre) * (1.0 + sheet_depth(source_uv));
		}
	}
	p = source_uv * 2.0 - 1.0;

	// Perspective tilt about the sheet centre, then zoom about it.
	float w = 1.0 + tilt_warp * (p.x * tan(tilt_rad.y) + p.y * tan(tilt_rad.x));
	p /= max(w, 0.2);
	p /= max(zoom, 1e-3);
	p += pan;

	vec2 uv = (p * 0.5 + 0.5);
	vec2 suv = page_lo + uv * span;
	vec2 sample_uv = (suv-texture_region.xy)/texture_region.zw;
	float footprint = 0.0;
	// Uniform guard: all fragments in a quad measure before any clipping or
	// per-pixel blur cutoff. Adjacent lanes may lie on opposite sides of either.
	if (blur_pyramid_ready && blur_radius > 0.0) {
		vec2 dx = dFdx(sample_uv) * vec2(textureSize(terminal_tex, 0));
		vec2 dy = dFdy(sample_uv) * vec2(textureSize(terminal_tex, 0));
		footprint = sqrt(0.5 * (dot(dx, dx) + dot(dy, dy)));
	}
	if (clipped) { discard; }
	if (!workspace_canvas && (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))) {
		// Off the page: leave the masonry alone apart from the shade.
		ALBEDO = vec3(0.0);
		ALPHA = 0.0;
	} else {
		if (any(lessThan(sample_uv,vec2(0.0))) || any(greaterThan(sample_uv,vec2(1.0)))) { discard; }
		vec4 ink = texture(terminal_tex, sample_uv);
		float radius = min(blur_limit, abs(1.0 - focus_depth / max(sheet_view_depth, 0.01)) * blur_radius);
		if (radius > 0.45 && blur_pyramid_ready) {
			vec4 sharp_ink = ink;
			// Convert rendered-pixel CoC into source-texel Gaussian sigma.
			// The pyramid is filtered densely before downsampling, so wide blur
			// never resolves into individual copies of the glyphs or noisy taps.
			float sigma = radius * 0.408248 * footprint;
			// Accumulated sigma of the half/quarter/eighth/sixteenth-size passes.
			if (sigma < 3.0) {
				ink = mix(ink, texture(terminal_blur_1, sample_uv), clamp(sigma * sigma / 9.0, 0.0, 1.0));
			} else if (sigma < 6.7082) {
				ink = mix(texture(terminal_blur_1, sample_uv), texture(terminal_blur_2, sample_uv), (sigma * sigma - 9.0) / 36.0);
			} else if (sigma < 13.7477) {
				ink = mix(texture(terminal_blur_2, sample_uv), texture(terminal_blur_3, sample_uv), (sigma * sigma - 45.0) / 144.0);
			} else {
				ink = mix(texture(terminal_blur_3, sample_uv), texture(terminal_blur_4, sample_uv), clamp((sigma * sigma - 189.0) / 576.0, 0.0, 1.0));
			}
			ink = mix(sharp_ink, ink, smoothstep(0.45, 1.25, radius));
		}
		if (page_count > 0) {
			vec2 texel = sample_uv * vec2(textureSize(terminal_tex, 0));
			ink = page_beneath(ink, page_0, page_rect_0, page_clip_0, page_radius_0, texel);
			if (page_count > 1) { ink = page_beneath(ink, page_1, page_rect_1, page_clip_1, page_radius_1, texel); }
			if (page_count > 2) { ink = page_beneath(ink, page_2, page_rect_2, page_clip_2, page_radius_2, texel); }
			if (page_count > 3) { ink = page_beneath(ink, page_3, page_rect_3, page_clip_3, page_radius_3, texel); }
		}
		// HDR 2D supplies linear, premultiplied coverage. Un-premultiply only
		// after filtering; blend_mix then applies coverage exactly once.
		// LDR sRGB premultiplication would darken antialiased glyph edges.
		vec3 ink_rgb = ink.rgb / max(ink.a, 1e-4);
		// terminal_shade darkens the wall across the panel, fading at the rim.
		vec2 rim = min(suv, 1.0 - suv);
		float shade = wall_shade * smoothstep(0.0, 0.04, min(rim.x, rim.y));

		// Rounded page corners, and a soft drop shadow outside the edge.
		float mask = 1.0;
		float outside = 0.0;
		if (corner_radius > 0.0 || edge_shadow > 0.0 || edge_blur > 0.0) {
			vec2 half_size = panel_rect.zw * tex_size * 0.5;
			float r = min(corner_radius, min(half_size.x, half_size.y));
			float d = rounded_box((suv - centre) * tex_size, half_size, r);
			mask = 1.0 - smoothstep(-max(edge_blur, 1.5), 0.0, d);
			if (edge_shadow > 0.0) {
				// Soft inward edge band, in framebuffer pixels.
				float band = clamp(1.0 + d / max(edge_shadow_width, 1.0), 0.0, 1.0);
				ink_rgb *= 1.0 - clamp(edge_shadow, 0.0, 1.0) * band * band;
			}
		}

		// Workspace glyphs are tinted in terminal_composite before backgrounds,
		// chrome and wires are composited. Standalone terminal sheets contain ink.
		vec3 lit = ink_rgb * (workspace_canvas ? vec3(1.0) : terminal_defocus_gain(sheet_view_depth));
		float lean = clamp((p.x * tilt_rad.y + p.y * tilt_rad.x) * 2.0 + 0.5, 0.0, 1.0);

		// Content gloss: a broad sheen tied to the same lean.
		lit += content_gloss * pow(lean, 3.0) * 0.12 * ink.a;

		// ALBEDO is un-premultiplied colour and ALPHA is pure coverage, so
		// blend_mix multiplies once.
		//
		// Keep it that way: if ALPHA ever carries something other than coverage
		// (the wall shade did once), the division above stops matching it and
		// glyphs come back bright on Metal.
		//
		// Glyph outlines are rasterized with terminal glyphs, excluding headers.
		vec3 ink_premultiplied = lit * ink.a * ink_gain;
		float ink_alpha = ink.a;
		float background_alpha = panel_opacity * mask;
		float alpha = ink_alpha + background_alpha * (1.0 - ink_alpha);
		ALBEDO = (ink_premultiplied + panel_color.rgb * background_alpha * (1.0 - ink_alpha))
			/ max(alpha * exposure_compensation, 1e-4);
		ALPHA = alpha;
// Keep sheet depth through glyph gaps for the screen-space filter.
	}
}
