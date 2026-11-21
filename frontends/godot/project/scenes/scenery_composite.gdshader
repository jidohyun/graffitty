shader_type canvas_item;
render_mode unshaded, blend_disabled;
#include "res://scenes/world_background.gdshaderinc"

void fragment() {
	COLOR = scenery_at(texture(TEXTURE, UV), UV, SCREEN_PIXEL_SIZE);
}
