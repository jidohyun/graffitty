shader_type canvas_item;
render_mode unshaded;
uniform float progress = 0.0;
uniform float depth_blur = 0.0;
uniform float depth_alpha = 1.0;
uniform vec2 extent = vec2(1600.0,1000.0);
uniform vec2 texture_size = vec2(1600.0,1000.0);
uniform vec2 terminal_origin = vec2(0.0);
uniform float flight_seed = 0.0;
uniform bool glyph_layer = false;
uniform bool dust_mode = false;
uniform int dust_count = 0;
#include "dust_motion.gdshaderinc"
uniform bool arrival_flight = false;
uniform float retirement_time = -1.0;
uniform float retirement_phase = 0.0;
varying float piece_alpha;
#include "scatter_motion.gdshaderinc"
void vertex() {
 piece_alpha = 1.0 - progress;
 if (dust_mode) {
  UV.y = 1.0 - UV.y;
  vec2 uv_center = INSTANCE_CUSTOM.xy + INSTANCE_CUSTOM.zw * 0.5;
  vec2 center = terminal_origin + uv_center * texture_size;
  vec2 size = INSTANCE_CUSTOM.zw * texture_size;
  float flight = retirement_time >= 0.0 ? scatter_retire(retirement_phase, COLOR.r, retirement_time) : scatter_clock(progress, COLOR.r, arrival_flight);
  float random = dust_hash(uv_center * texture_size);
  float depth = min(extent.x, extent.y);
  vec2 jitter = vec2(0.5) + (vec2(random, fract(random * 13.7)) - 0.5) * 0.16;
  vec2 wind = scatter_wind(center / extent, jitter);
  vec3 displacement = scatter_travel(flight, (center - extent * 0.5) / depth, wind, scatter_drift(center / extent, jitter, wind), arrival_flight);
  displacement.xy += dust_turbulence(flight, random) * vec2(arrival_flight ? -1.0 : 1.0, 1.0);
  float perspective = 1.0 / max(1.0 - displacement.z, 0.01);
  float angle = flight * (random - 0.5) * 2.4;
  VERTEX = (mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * (VERTEX * size)) / size;
  VERTEX *= max(0.015, 1.0 - 1.5 * flight);
  VERTEX = VERTEX * perspective + ((center - extent * 0.5) * (perspective - 1.0) + displacement.xy * depth * perspective) / size;
  piece_alpha = displacement.z < 0.99 ? scatter_opacity(flight) * (1.0 - smoothstep(0.35, 0.85, flight)) : 0.0;
  UV = INSTANCE_CUSTOM.xy + UV * INSTANCE_CUSTOM.zw;
 }

 if (glyph_layer) {
  // QuadMesh uses +Y for the top edge; CanvasItem coordinates use +Y down.
  UV.y = 1.0 - UV.y;
  float seed = fract(sin(dot(INSTANCE_CUSTOM.xy, vec2(127.1, 311.7))) * 43758.5453);
  float flight = retirement_time >= 0.0 ? scatter_retire(retirement_phase, COLOR.r, retirement_time) : scatter_clock(progress, COLOR.r, arrival_flight);
  vec2 size = max(INSTANCE_CUSTOM.zw * texture_size, vec2(1.0));
  float angle = scatter_spin(flight, vec3(fract(seed * 5.13), fract(seed * 13.37), fract(seed * 3.77)));
  // Rotate in pixel space so a wide text run stays rigid through a full turn.
  VERTEX = (mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * (VERTEX * size)) / size;
  vec2 pane_center = INSTANCE_CUSTOM.xy + INSTANCE_CUSTOM.zw * 0.5;
  vec2 center = terminal_origin + pane_center * texture_size;
  float depth = min(extent.x, extent.y);
  vec2 jitter = fract(vec2(seed) * vec2(5.13, 13.37));
  vec2 wind = scatter_wind(center / extent, jitter);
  vec2 drift = scatter_drift(center / extent, jitter, wind);
  vec3 displacement = scatter_travel(flight, (center - extent * 0.5) / depth, wind, drift, arrival_flight);
  float perspective = 1.0 / max(1.0 - displacement.z, 0.01);
  VERTEX = VERTEX * perspective + ((center - extent * 0.5) * (perspective - 1.0)
    + displacement.xy * depth * perspective) / size;
  UV = INSTANCE_CUSTOM.xy + UV * INSTANCE_CUSTOM.zw;
  // Emulate the 3D near plane, avoiding mirrored quads behind the camera.
  piece_alpha = displacement.z < 0.99 ? scatter_opacity(flight) : 0.0;
 }
}
void fragment() {
 vec4 ink = texture(TEXTURE,UV);
 if (depth_blur > 0.45) {
  vec2 dx = dFdx(UV) * depth_blur;
  vec2 dy = dFdy(UV) * depth_blur;
  vec4 sum = vec4(0.0);
  float weights = 0.0;
  for (int y = -2; y <= 2; y++) {
   for (int x = -2; x <= 2; x++) {
    vec2 offset = vec2(float(x), float(y)) * 0.5;
    float weight = exp(-3.0 * dot(offset, offset));
    vec2 uv = UV + dx * offset.x + dy * offset.y;
    if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
     sum += texture(TEXTURE, uv) * weight;
    }
    weights += weight;
   }
  }
  ink = mix(ink, sum / weights, smoothstep(0.45, 1.25, depth_blur));
 }

 COLOR = vec4(ink.rgb / max(ink.a,0.0001), ink.a * piece_alpha * depth_alpha);
}
