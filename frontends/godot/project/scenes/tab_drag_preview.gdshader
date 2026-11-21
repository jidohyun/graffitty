shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

uniform sampler2D world_texture : filter_linear, repeat_disable;
uniform float header_fraction = 0.0;

void fragment() {
	// Both live viewport textures already contain premultiplied coverage.
	// Remove the source's tab labels while keeping scenery visible through the
	// preview's selected tab. Below the header retain the complete window UI.
	COLOR = UV.y < header_fraction ? texture(world_texture, UV) : texture(TEXTURE, UV);
}
