shader_type canvas_item;
render_mode unshaded;
// Project the retained image layers independently, before the shared sheet
// camera. Text stays on its own layer; the native z ordering stays intact.
uniform mat3 plane_projection = mat3(1.0);
varying vec3 projected_uv;
varying vec4 vertex_color;
void vertex() {
	vertex_color = COLOR;
	vec3 projected = plane_projection * vec3(VERTEX, 1.0);
	VERTEX = projected.xy / max(projected.z, 0.001);
	projected_uv = vec3(UV, 1.0) / max(projected.z, 0.001);
}
void fragment() {
	// Fragment COLOR already includes a sample at the uncorrected UV.
	// Use the vertex tint so the image is sampled only at its projected UV.
	COLOR = vertex_color * texture(TEXTURE, projected_uv.xy / projected_uv.z);
}
