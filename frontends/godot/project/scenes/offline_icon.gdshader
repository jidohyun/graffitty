shader_type canvas_item;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec4 pixel = texture(TEXTURE, UV);
	float luminance = dot(pixel.rgb, vec3(0.2126, 0.7152, 0.0722));
	COLOR = tint * vec4(vec3(luminance), pixel.a * 0.55);
}
