shader_type spatial;
instance uniform float workspace_clip_top = 0.0;
render_mode unshaded, cull_disabled, blend_mix, shadows_disabled, depth_draw_never;
// Test against scenery, but never let translucent streaks occlude one another.
uniform bool sparks = true;
uniform mat4 presentation_transform = mat4(1.0);
uniform float exposure_compensation = 1.0;
uniform float focus_depth = 1.0;
uniform float blur_radius = 0.0;
varying flat vec4 spark_shape;
varying flat vec4 spark_needle;
varying vec4 spark_tint;
#include "res://scenes/terminal_particle_light.gdshaderinc"

void vertex() {
    bool is_spark = INSTANCE_CUSTOM.w > 0.0;
    // Filament quantizes the seed before sharing it between shader stages.
    float seed = floor(INSTANCE_CUSTOM.z * 4096.0 + 0.5) / 4096.0;
    float age = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
    float depth = max(-(VIEW_MATRIX * presentation_transform * MODEL_MATRIX[3]).z, 0.01);
    // Viewport render targets flip Y, so the projection scale can be negative.
    float world_per_pixel = 2.0 * depth / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
    float size = max(INSTANCE_CUSTOM.x, 0.5);
    float pixel_scale = max(length((presentation_transform * vec4(MODEL_MATRIX[0].xyz, 0.0)).xyz), 0.000001);
    float blur = min(16.0, abs(1.0 - focus_depth / depth) * blur_radius) * world_per_pixel / pixel_scale;
    vec2 centre = UV - vec2(0.5);
    vec2 local;
    if (is_spark) {
        // Source-pixel velocity, not view-space velocity. The whole shape is
        // projected with the terminal plane below, as in live-particle.mat.
        vec2 streak = spark_streak_vector(MODEL_MATRIX[2].xy * 0.045
            * (0.6 + 0.9 * spark_hash(seed, 0.0)), seed, age);
        float len = length(streak);
        vec2 dir = len > 0.0001 ? streak / len : vec2(1.0, 0.0);
        float glow = 0.6 + 0.9 * spark_hash(seed, 1.0);
        float pad = size * (2.5 + 1.5 * glow) + 4.0 * blur;
        SparkForm form = spark_form(seed, len * 0.5, 1.0);
        float half_l = (len * 0.5 + pad + max(form.fork_len, form.fork2_len)) / 0.86;
        float half_w = (pad + (abs(form.bend_px) + abs(form.kink_px) + max(form.fork_lat, form.fork2_lat) + size) * 1.6) / 0.86;
        local = dir * (centre.x * 2.0 * half_l - len * 0.5)
              + vec2(-dir.y, dir.x) * (centre.y * 2.0 * half_w);
        spark_shape = vec4(len * 0.5, half_l, half_w, glow);
        spark_needle = vec4(size, age, seed, blur);
    } else {
        float extent = size + 8.0 * blur;
        local = centre * extent;
        spark_shape = vec4(0.0, 0.0, extent, 0.0);
        spark_needle = vec4(size, age, seed, blur);
    }
    vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * local.x + MODEL_MATRIX[1].xyz * local.y;
    POSITION = PROJECTION_MATRIX * VIEW_MATRIX * presentation_transform * vec4(world, 1.0);
    spark_tint = COLOR;
}

void fragment() {
    if (SCREEN_UV.y < workspace_clip_top) { discard; }
    vec4 light = particle_light(UV, spark_tint, spark_shape, spark_needle, OUTPUT_IS_SRGB);
    ALBEDO = light.rgb / max(light.a, 0.00001) / max(exposure_compensation, 0.0001);
    ALPHA = light.a;
    if (light.a < 0.001) { discard; }
}
