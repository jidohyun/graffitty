shader_type spatial;
// Light photogrammetry scenery with albedo, one sun, and ambient light.
//
// Compare this shader with StandardMaterial3D to measure the cost of
// specular shading, image-based lighting, and clustered lights.
render_mode unshaded, cull_back, shadows_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec3 sun_direction = vec3(0.3, -0.7, -0.35);
uniform vec3 sun_color = vec3(1.0, 0.95, 0.86);
uniform float sun_strength = 1.6;
uniform vec3 ambient_color = vec3(0.62, 0.66, 0.74);
uniform float ambient_strength = 0.35;

varying vec3 world_normal;

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 albedo = texture(albedo_tex, UV).rgb;
	float lambert = max(dot(world_normal, -normalize(sun_direction)), 0.0);
	ALBEDO = albedo * (ambient_color * ambient_strength + sun_color * sun_strength * lambert);
}
