shader_type spatial;
// Use a simple lighting model for the stone meshes. The GLB has 100
// materials. Of those, 25 use normal maps. All use a constant metallic
// factor, with no specular or metallic maps.
//
// Skipping StandardMaterial3D's per-pixel GGX specular and image-based
// lighting reduced fullscreen frame time from 25.8 ms to 10.8 ms with
// the same geometry and albedo.
//
// Godot still supplies shadows, both directional lights, and ambient light.
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform vec4 albedo_factor : source_color = vec4(1.0);
uniform float roughness_factor : hint_range(0.0, 1.0) = 1.0;
uniform bool has_normal = false;

void fragment() {
	vec4 base = texture(albedo_tex, UV) * albedo_factor;
	ALBEDO = base.rgb;
	ROUGHNESS = roughness_factor;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
}
