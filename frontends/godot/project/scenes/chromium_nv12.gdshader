shader_type canvas_item;
// Remote Chromium video decoded as NV12: full-resolution luma and half-
// resolution interleaved chroma. BT.601 limited range, the matrix of the CPU
// conversion it replaces; filtering upsamples chroma between its samples.
uniform sampler2D luma : filter_linear, repeat_disable;
uniform sampler2D chroma : filter_linear, repeat_disable;

void fragment() {
	float y = (texture(luma, UV).r - 16.0 / 255.0) * 1.164384;
	vec2 c = texture(chroma, UV).rg - vec2(128.0 / 255.0);
	COLOR = vec4(y + 1.596027 * c.y, y - 0.391762 * c.x - 0.812968 * c.y, y + 2.017232 * c.x, 1.0);
}
