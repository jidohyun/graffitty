shader_type canvas_item;
render_mode unshaded, skip_vertex_transform;
#include "res://scenes/terminal_particle_light.gdshaderinc"
varying flat vec4 spark_shape;
varying flat vec4 spark_needle;
varying vec4 spark_tint;
void vertex() {
 bool is_spark = INSTANCE_CUSTOM.w > 0.0;
 float seed = floor(INSTANCE_CUSTOM.z * 4096.0 + 0.5) / 4096.0;
 float age = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
 float size = max(INSTANCE_CUSTOM.x, 0.5);
 float unit = max(length(MODEL_MATRIX[0].xy), 0.000001);
 vec2 centre = UV - vec2(0.5);
 vec2 local;
 if (is_spark) {
  vec2 velocity = MODEL_MATRIX[0].xy / unit * INSTANCE_CUSTOM.w;
  vec2 streak = spark_streak_vector(velocity * 0.045 * (0.6 + 0.9 * spark_hash(seed, 0.0)), seed, age);
  float len = length(streak);
  vec2 dir = len > 0.0001 ? streak / len : vec2(1.0, 0.0);
  float glow = 0.6 + 0.9 * spark_hash(seed, 1.0);
  float pad = size * (2.5 + 1.5 * glow);
  SparkForm form = spark_form(seed, len * 0.5, 1.0);
  float half_l = (len * 0.5 + pad + max(form.fork_len, form.fork2_len)) / 0.86;
  float half_w = (pad + (abs(form.bend_px) + abs(form.kink_px) + max(form.fork_lat, form.fork2_lat) + size) * 1.6) / 0.86;
  local = dir * (centre.x * 2.0 * half_l - len * 0.5) + vec2(-dir.y, dir.x) * (centre.y * 2.0 * half_w);
  spark_shape = vec4(len * 0.5, half_l, half_w, glow);
 } else {
  local = centre * size;
  spark_shape = vec4(0.0, 0.0, size, 0.0);
 }
 spark_needle = vec4(size, age, seed, 0.0);
 VERTEX = MODEL_MATRIX[3].xy + local * unit;
 spark_tint = COLOR;
}
void fragment() {
 // The Flat 2D canvas uses HDR. Compatibility draws its canvas in sRGB.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
 const bool output_srgb = true;
#else
 const bool output_srgb = false;
#endif
 vec4 light = particle_light(UV, spark_tint, spark_shape, spark_needle, output_srgb);
 COLOR = vec4(light.rgb / max(light.a, 0.00001), light.a);
}
