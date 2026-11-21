shader_type spatial;
instance uniform float workspace_clip_top = 0.0;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec4 trail_color : source_color = vec4(1.0);
uniform float exposure_compensation = 1.0;
uniform vec4 cursor_rect = vec4(0.0);
#include "cursor_trail_styles.gdshaderinc"
void fragment() {
    if (SCREEN_UV.y < workspace_clip_top) { discard; }
    vec4 ink = cursor_trail_ink(UV, trail_color);
    ALBEDO = ink.rgb / max(exposure_compensation, 0.0001);
    ALPHA = ink.a;
}
