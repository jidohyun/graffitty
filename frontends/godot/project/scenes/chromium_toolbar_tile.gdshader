shader_type canvas_item;
render_mode unshaded;
uniform vec2 slice = vec2(0.0, 1.0);
uniform bool encode_srgb = true;
varying vec4 tint;
void vertex() { tint = COLOR; }
vec3 linear_to_srgb(vec3 c) {
	return mix(1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, 12.92 * c, lessThanEqual(c, vec3(0.0031308)));
}
void fragment() {
	vec4 ink = texture(TEXTURE, vec2(slice.x + UV.x * slice.y, UV.y));
#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
	// Compatibility already stores the captured toolbar in sRGB.
	if (encode_srgb) ink.rgb = linear_to_srgb(ink.rgb);
#endif
	// The captured toolbar has premultiplied coverage.
	COLOR = tint * vec4(ink.rgb / max(ink.a, 0.0001), ink.a);
}
