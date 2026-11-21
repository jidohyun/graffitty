shader_type canvas_item;
// Replace the already-composited backdrop rather than blending it over itself.
// Only the panel's stylebox uses this material; children remain sharp.
render_mode unshaded, blend_disabled;
uniform sampler2D backdrop : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float radius : hint_range(0.0, 128.0) = 12.0;
uniform float surface_opacity : hint_range(0.0, 1.0) = 0.8;
// Embedded windows paint their own tint in a separate viewport.
uniform bool tint_surface = true;

void fragment() {
	vec4 original = textureLod(backdrop, SCREEN_UV, 0.0);
	// Mipmap filtering gives a bounded-cost low-pass filter on every canvas
	// renderer, including Compatibility. Radius is in framebuffer pixels.
	float lod = log2(max(radius, 1.0));
	vec4 blurred = textureLod(backdrop, SCREEN_UV, lod);
	float coverage = clamp(COLOR.a / max(surface_opacity, 0.0001), 0.0, 1.0);
	// Screen pixels are premultiplied. Preserve their alpha so the main window's
	// compositor can still show/blur the desktop behind translucent content.
	vec4 tinted = vec4(COLOR.rgb * surface_opacity + blurred.rgb * (1.0 - surface_opacity),
		surface_opacity + blurred.a * (1.0 - surface_opacity));
	COLOR = mix(original, tint_surface ? tinted : blurred, coverage);
}
