// Viewport textures encode premultiplied linear light as sRGB. Keep all
// composition in linear light, including translucent wallpaper pixels.
uniform vec4 world_background = vec4(0.0);
uniform bool wallpaper_enabled = false;
uniform sampler2D wallpaper_texture : repeat_disable, filter_linear;

vec3 to_linear(vec3 color) {
	return mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), color));
}

vec3 to_srgb(vec3 color) {
	return mix(color * 12.92, 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), color));
}

vec4 over(vec4 front, vec4 back) {
	return vec4(to_srgb(to_linear(front.rgb) + to_linear(back.rgb) * (1.0 - front.a)),
		front.a + back.a * (1.0 - front.a));
}

vec4 world_background_at(vec2 uv, vec2 pixel_size) {
	vec4 fill = world_background;
	if (wallpaper_enabled) {
		vec2 image_size = vec2(textureSize(wallpaper_texture, 0));
		float relative_aspect = (pixel_size.y / pixel_size.x) / (image_size.x / image_size.y);
		// Centered cover: crop overflow, never leave a letterboxed edge.
		vec2 crop = vec2(min(relative_aspect, 1.0), min(1.0 / relative_aspect, 1.0));
		fill *= texture(wallpaper_texture, (uv - 0.5) * crop + 0.5);
	}
	return vec4(to_linear(fill.rgb) * fill.a, fill.a);
}

// Takes the sample, not the sampler: Godot cannot pass the built-in TEXTURE
// to a function.
vec4 scenery_at(vec4 front, vec2 uv, vec2 pixel_size) {
	vec4 fill = world_background_at(uv, pixel_size);
	return vec4(to_srgb(to_linear(front.rgb) + fill.rgb * (1.0 - front.a)),
		front.a + fill.a * (1.0 - front.a));
}
