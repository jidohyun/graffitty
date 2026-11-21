// Shared depth response for terminal ink. This changes RGB, never coverage.
// Lens focus and depth normalization are supplied by TerminalEffects.update_lens.
uniform float defocus_focus_depth = 1.0;
uniform float defocus_depth_range = 0.0263;
uniform float defocus_weight = 0.0;
uniform float defocus_strength = 0.5;
uniform float defocus_minimum = 0.45;
uniform vec3 dof_blur_tint : source_color = vec3(0.616, 0.698, 0.839);
uniform float dof_blur_tint_strength = 1.0;

vec3 terminal_defocus_gain(float view_depth) {
	float distance_from_focus = abs(1.0 - defocus_focus_depth / max(view_depth, 0.01));
	float response = distance_from_focus / max(defocus_depth_range, 0.0001)
			* max(defocus_strength, 0.0) * clamp(defocus_weight, 0.0, 1.0);
	float amount = 1.0 - exp(-response);
	float level = mix(1.0, clamp(defocus_minimum, 0.0, 1.0), amount);
	vec3 lum = vec3(0.2126, 0.7152, 0.0722);
	vec3 color = dof_blur_tint / max(dot(dof_blur_tint, lum), 0.0001);
	return level * mix(vec3(1.0), color, amount * clamp(dof_blur_tint_strength, 0.0, 1.0));
}
