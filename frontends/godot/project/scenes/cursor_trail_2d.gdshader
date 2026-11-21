shader_type canvas_item;
render_mode unshaded;
uniform vec4 trail_color : source_color = vec4(1.0);
uniform float exposure_compensation = 1.0;
uniform vec4 cursor_rect = vec4(0.0);
#include "cursor_trail_styles.gdshaderinc"
void fragment() {
    vec4 ink = cursor_trail_ink(UV, trail_color);
    COLOR = vec4(ink.rgb / max(exposure_compensation, 0.0001), ink.a);
}
