shader_type spatial;
// Forward+ focuses each workspace in its own screen-space pass before alpha
// composition. The fragment lens serves renderers without storage attachments.
render_mode unshaded, cull_disabled, blend_mix, shadows_disabled, world_vertex_coords, depth_draw_always;
instance uniform float workspace_clip_top = 0.0;
uniform float stack_depth_bias = 0.0000003;
#include "terminal_defocus.gdshaderinc"
uniform vec3 source_depth_plane = vec3(1.0, 0.0, 0.0);
uniform float focus_depth = 1.0;
uniform float blur_radius = 0.0;
uniform float blur_limit = 24.0;
uniform bool screen_dof = false;
uniform sampler2D terminal_tex : filter_linear, source_color;
uniform vec2 cell_uv = vec2(1.0);
uniform vec3 plane_a_origin;
uniform vec3 plane_a_du;
uniform vec3 plane_a_dv;
uniform float depth_direction = 1.0;
uniform float depth_zoom_ratio = 2.0;
uniform mat4 depth_transform = mat4(1.0);
uniform float depth_opacity = 1.0;
uniform float fly = 0.0;
uniform bool arrival_flight = false;
uniform bool camera_relative_flight = false;
uniform mat4 flight_camera_transform;
uniform vec3 flight_camera_eye;
uniform float ink_gain = 1.0;
uniform float exposure_compensation = 1.0;
#include "piece_sheet_projection.gdshaderinc"
varying vec2 source_uv;
varying float opacity;
varying float blur;
varying float source_ink_depth;
varying float piece_depth;
void vertex() {
 source_uv = INSTANCE_CUSTOM.xy + UV * cell_uv;
 vec2 sheet_uv = projected_piece_uv(source_uv);
 source_ink_depth = dot(source_depth_plane, vec3(1.0, source_sheet_rect.xy + sheet_uv * source_sheet_rect.zw));
 vec3 assembled = plane_a_origin + plane_a_du * sheet_uv.x + plane_a_dv * sheet_uv.y;
 // The renderer and cursor model consume the same transform.
 VERTEX = (depth_transform * vec4(assembled, 1.0)).xyz;
 float phase = fly;
 piece_depth = -(VIEW_MATRIX * vec4(VERTEX, 1.0)).z;
 opacity = (1.0 - phase) * depth_opacity;
 blur = phase * 6.0;
}
void fragment() {
 // Take derivatives before clipping or the per-pixel focus cutoff splits a quad.
 vec2 uv_dx = dFdx(source_uv);
 vec2 uv_dy = dFdy(source_uv);
 if (SCREEN_UV.y < workspace_clip_top || opacity <= 0.0001) { discard; }
 DEPTH = clamp(FRAGCOORD.z + stack_depth_bias, 0.0, 1.0);
 vec4 ink = texture(terminal_tex, source_uv);
 float radius = min(blur_limit, max(blur, abs(1.0 - focus_depth / max(piece_depth, 0.01)) * blur_radius));
 if (!screen_dof && radius > 0.45) {
  vec2 dx = uv_dx * radius;
  vec2 dy = uv_dy * radius;
  vec4 sum = vec4(0.0);
  float weights = 0.0;
  for (int y = -2; y <= 2; y++) {
   for (int x = -2; x <= 2; x++) {
    vec2 offset = vec2(float(x), float(y)) * 0.5;
    float weight = exp(-3.0 * dot(offset, offset));
    vec2 uv = source_uv + dx * offset.x + dy * offset.y;
    if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
     sum += texture(terminal_tex, uv) * weight;
    }
    weights += weight;
   }
  }
  ink = mix(ink, sum / weights, smoothstep(0.45, 1.25, radius));
 }
 ALBEDO = ink.rgb / max(ink.a, 0.0001) * terminal_defocus_gain(source_ink_depth) * ink_gain / max(exposure_compensation, 0.0001);
 ALPHA = ink.a * opacity;
 if (ALPHA <= 0.0001) { discard; }
}
