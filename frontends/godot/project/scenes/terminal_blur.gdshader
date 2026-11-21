shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform vec2 axis;
uniform sampler2D input_texture : filter_linear, repeat_disable, source_color;

vec4 sample_ink(vec2 uv) {
    vec2 half_texel = 0.5 / vec2(textureSize(input_texture, 0));
    return texture(input_texture, clamp(uv, half_texel, vec2(1.0) - half_texel));
}

void fragment() {
    // Gaussian sigma=1.5. Horizontal then vertical; premultiplied throughout.
    vec4 ink = sample_ink(UV) * 0.26656;
    if (axis.x == 0.0) {
        // The vertical pass samples an equal-sized input at texel centers.
        // A bilinear read can combine each adjacent pair of Gaussian taps.
        vec2 near_pair = axis * (1.0 + 0.10959 / (0.21344 + 0.10959));
        vec2 far_pair = axis * (3.0 + 0.00761 / (0.03607 + 0.00761));
        ink += (sample_ink(UV - near_pair) + sample_ink(UV + near_pair)) * (0.21344 + 0.10959);
        ink += (sample_ink(UV - far_pair) + sample_ink(UV + far_pair)) * (0.03607 + 0.00761);
    } else {
        // Horizontal also downsamples, so its taps need separate reads.
        ink += (sample_ink(UV - axis) + sample_ink(UV + axis)) * 0.21344;
        ink += (sample_ink(UV - axis * 2.0) + sample_ink(UV + axis * 2.0)) * 0.10959;
        ink += (sample_ink(UV - axis * 3.0) + sample_ink(UV + axis * 3.0)) * 0.03607;
        ink += (sample_ink(UV - axis * 4.0) + sample_ink(UV + axis * 4.0)) * 0.00761;
    }
    COLOR = ink / 0.99998;
}
