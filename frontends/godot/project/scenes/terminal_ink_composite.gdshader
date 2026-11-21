shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D scenery_texture : repeat_disable, filter_linear;
uniform float backdrop_blur_radius = 0.0;
uniform float workspace_clip_top = 0.0;
uniform int transition_count = 0;
uniform int transition_foreground_mask = 0;
uniform sampler2D transition_0 : repeat_disable, filter_linear;
uniform sampler2D transition_1 : repeat_disable, filter_linear;
uniform sampler2D transition_2 : repeat_disable, filter_linear;
uniform sampler2D transition_3 : repeat_disable, filter_linear;

#include "res://scenes/world_background.gdshaderinc"

void fragment() {
	// The full scenery pass already draws underneath this foreground overlay.
	if (UV.y < workspace_clip_top) { discard; }
	vec4 ink = texture(TEXTURE, UV);
	vec4 retained = vec4(0.0);
	vec4 foreground = vec4(0.0);
	for (int i = 0; i < transition_count; i++) {
		vec4 layer;
		if (i == 0) { layer = texture(transition_0, UV); }
		else if (i == 1) { layer = texture(transition_1, UV); }
		else if (i == 2) { layer = texture(transition_2, UV); }
		else { layer = texture(transition_3, UV); }
		if ((transition_foreground_mask & (1 << i)) != 0) { foreground = over(layer, foreground); }
		else { retained = over(layer, retained); }
	}
	if (transition_count > 0) { ink = over(foreground, over(ink, retained)); }
	vec4 background = scenery_at(texture(scenery_texture, UV), UV, SCREEN_PIXEL_SIZE);
	// Filter scenery only: the terminal texture (including glyphs and headers)
	// is never sampled at neighboring pixels.
	if (backdrop_blur_radius > 0.0 && ink.a > 0.001 && ink.a < 0.999) {
		vec2 step_uv = vec2(backdrop_blur_radius) / vec2(textureSize(scenery_texture, 0));
		vec4 sum = vec4(0.0);
		float weight_sum = 0.0;
		for (int y = -2; y <= 2; y++) {
			for (int x = -2; x <= 2; x++) {
				float weight = exp(-float(x*x + y*y) * 0.5);
				vec4 sample_color = scenery_at(texture(scenery_texture, UV + vec2(float(x), float(y)) * step_uv * 0.5), UV + vec2(float(x), float(y)) * step_uv * 0.5, SCREEN_PIXEL_SIZE);
				sum += vec4(to_linear(sample_color.rgb), sample_color.a) * weight;
				weight_sum += weight;
			}
		}
		background = vec4(to_srgb(sum.rgb / weight_sum), sum.a / weight_sum);
	}
	// 3D viewport textures encode premultiplied linear light as sRGB.
	// Match the combined 3D pass before encoding the result for the canvas.
	COLOR = vec4(to_srgb(to_linear(ink.rgb) + to_linear(background.rgb) * (1.0 - ink.a)),
		ink.a + background.a * (1.0 - ink.a));
}
