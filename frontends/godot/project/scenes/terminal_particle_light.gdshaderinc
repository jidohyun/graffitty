// Shared luminous spark shape for the 2D and 3D renderers.
float saturate(float value) { return clamp(value, 0.0, 1.0); }
vec3 srgb2linear(vec3 v) { return mix(v / 12.92, pow((v + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), v)); }
vec3 linear2srgb(vec3 v) { return mix(v * 12.92, 1.055 * pow(max(v, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), v)); }
float
spark_hash(float seed, float n) {
    return fract(sin(seed * 127.1 + n * 311.7 + 0.5) * 43758.5453);
}

struct SparkForm {
    float core_mul;  // core thickness, 0.7 to 1.4
    float bend_px;   // how far the tail bends across, signed
    float kink_px;   // a second, opposing bend that keeps the spine organic
    float forked;    // first fork's smooth age-dependent growth, 0 to 1
    float fork_x;    // where the fork leaves the spine, along the streak from its centre
    vec2 fork_dir; // the fork's direction: toward the tail, off to the crooked side
    float fork_len;  // how far the fork runs, px
    float fork_lat;  // how far across it reaches, px, for the quad's room
    float fork2ed;   // rarer second fork, also grown continuously
    float fork2_x;
    vec2 fork2_dir;
    float fork2_len;
    float fork2_lat;
};

// The one derivation both stages use, so the vertex reserves exactly the
// room the fragment draws in.
SparkForm
spark_form(float seed, float half_len, float age) {
    SparkForm f;
    f.core_mul = 0.7 + 0.7 * spark_hash(seed, 2.0);
    float disorder = smoothstep(0.12, 0.90, age);
    float crook = 2.0 * spark_hash(seed, 3.0) - 1.0;
    f.bend_px = crook * min(4.5, 0.24 * half_len) * (0.32 + 0.68 * disorder);
    f.kink_px = (2.0 * spark_hash(seed, 8.0) - 1.0) * min(2.6, 0.14 * half_len)
        * (0.22 + 0.78 * disorder);
    float fork = spark_hash(seed, 4.0);
    float fork_start = 0.22 + 0.10 * spark_hash(seed, 9.0);
    f.forked = fork > 0.58 ? smoothstep(fork_start, fork_start + 0.22, age) : 0.0;
    // The fork's root sits part way down the streak, never at its ends.
    float root = 0.28 + 0.40 * spark_hash(seed, 5.0);
    f.fork_x = -half_len + root * 2.0 * half_len;
    float ang = 0.42 + 0.53 * spark_hash(seed, 10.0);
    float side = crook >= 0.0 ? 1.0 : -1.0;
    f.fork_dir = vec2(-cos(ang), side * sin(ang));
    float fork_full_len = min(4.0 + 7.0 * spark_hash(seed, 11.0), max(2.0, 0.80 * half_len));
    f.fork_len = f.forked * fork_full_len;
    f.fork_lat = abs(f.fork_dir.y) * f.fork_len;

    // A much rarer second twig appears later and is deliberately unequal to
    // the first, avoiding a symmetric star/snowflake silhouette.
    float fork2 = spark_hash(seed, 12.0);
    float fork2_start = 0.42 + 0.14 * spark_hash(seed, 13.0);
    f.fork2ed = fork2 > 0.86 ? smoothstep(fork2_start, fork2_start + 0.24, age) : 0.0;
    float root2 = 0.34 + 0.38 * spark_hash(seed, 14.0);
    f.fork2_x = -half_len + root2 * 2.0 * half_len;
    float ang2 = 0.32 + 0.42 * spark_hash(seed, 15.0);
    float side2 = spark_hash(seed, 16.0) > 0.35 ? -side : side;
    f.fork2_dir = vec2(-cos(ang2), side2 * sin(ang2));
    float fork2_full_len = min(3.0 + 5.0 * spark_hash(seed, 17.0), max(1.5, 0.65 * half_len));
    f.fork2_len = f.fork2ed * fork2_full_len;
    f.fork2_lat = abs(f.fork2_dir.y) * f.fork2_len;
    return f;
}

// Incandescent fragments mostly point along their motion, but each carries a
// small fixed misalignment that grows smoothly as it tumbles.
//
// A rare chip can turn farther; nothing is time-hashed, so it never shimmers
// between frames.
vec2
spark_streak_vector(vec2 velocity_streak, float seed, float age) {
    float magnitude = length(velocity_streak);
    if (magnitude <= 1e-4) return velocity_streak;
    // A newborn shower shares one rising axis, then opens continuously into
    // the particles' physical directions. This gives the fountain a source
    // without pinning older fragments into an artificial radial star.
    float young = smoothstep(0.10, 0.38, age);
    vec2 coherent = vec2(0.0, -magnitude);
    float open = 0.22 + 0.78 * young;
    float axis_cross = coherent.x * velocity_streak.y - coherent.y * velocity_streak.x;
    float axis_dot = dot(coherent, velocity_streak);
    float sweep = open * atan(axis_cross, axis_dot);
    float sweep_s = sin(sweep), sweep_c = cos(sweep);
    vec2 axis = vec2(coherent.x * sweep_c - coherent.y * sweep_s,
                               coherent.x * sweep_s + coherent.y * sweep_c);
    float signed_turn = 2.0 * spark_hash(seed, 18.0) - 1.0;
    float rare = smoothstep(0.90, 1.0, spark_hash(seed, 19.0));
    float disorder = smoothstep(0.14, 0.92, age);
    float turn = signed_turn * (0.055 + 0.075 * spark_hash(seed, 20.0) + 0.18 * rare)
        * (0.45 + 0.75 * disorder);
    float st = sin(turn), ct = cos(turn);
    return vec2(axis.x * ct - axis.y * st,
                  axis.x * st + axis.y * ct);
}

// Quad corners in GL_TRIANGLE_FAN order, matching draw_quad().

float
spark_gaussian(float distance, float width, float segment_len, float blur) {
    if (blur <= 0.0) return exp(-(distance * distance) / (2.0 * width * width));
    float widened = sqrt(width * width + blur * blur);
    float energy = (width / widened)
        * (segment_len + 2.5066283 * width) / (segment_len + 2.5066283 * widened);
    return exp(-(distance * distance) / (2.0 * widened * widened)) * energy;
}

float
spark_core(float distance, float radius, float aa, float segment_len, float blur) {
    float sharp = 1.0 - smoothstep(-aa, aa * 0.5, distance - radius);
    if (blur <= 0.0) return sharp;
    // Match the integral of the antialiased cross section to a Gaussian,
    // then use its analytic defocus once the blur resolves that section.
    // The smooth transition preserves the solid metal edge near focus.
    float t = saturate((aa - radius) / (1.5 * aa));
    float integral = max(radius - aa, 0.0)
        + 1.5 * aa * (0.5 - t + t * t * t - 0.5 * t * t * t * t);
    float width = max(0.8 * radius, 0.2 * aa);
    float peak = min(1.0, 2.0 * integral / (2.5066283 * width));
    float defocused = peak * spark_gaussian(distance, width, segment_len, blur);
    return mix(sharp, defocused, smoothstep(0.0, width, blur));
}


vec4 particle_light(vec2 uv, vec4 tint, vec4 shape, vec4 needle, bool output_srgb)
{
    if (shape.y > 0.0) {
        float half_len = shape.x, glow = shape.w, size = max(needle.x, 0.5), age = saturate(needle.y);
        float blur = needle.w, segment_len = 2.0 * half_len;
        // This spark's own shape, from the seed it was born with: how thick
        // its core is, how far and which way its tail bends, and how its
        // asymmetric branches develop as it travels.
        SparkForm form = spark_form(needle.z, half_len, age);
        // Pixel offsets from the streak's centre, along it (the head at +x)
        // and across it.
        float ax = (uv.x - 0.5) * 2.0 * shape.y;
        float ay_raw = (uv.y - 0.5) * 2.0 * shape.z;
        // s runs from 0 at the tail to 1 at the head.
        float s = half_len > 1e-3 ? saturate((ax + half_len) / (2.0 * half_len)) : 1.0;
        // A broad C-bend plus a weaker opposing kink: still recognisably a
        // fast luminous line, but not a ruled capsule.
        //
        // Both taper into the head and grow continuously with age rather than
        // changing shape at a frame boundary.
        float tail = 1.0 - s;
        float centre = form.bend_px * tail * tail
            + form.kink_px * sin(6.2831853 * s) * tail;
        float ay = ay_raw - centre;
        float along = clamp(ax, -half_len, half_len);
        float d = length(vec2(ax - along, ay));
        // A needle: the metal's full radius at the head, drawn out to a
        // point at the tail. A low-frequency, seed-fixed thickness change
        // keeps neighbouring fragments from sharing one manufactured edge.
        float rough = 0.82 + 0.18 * (0.5 + 0.5 * sin(
            (4.0 + 3.0 * spark_hash(needle.z, 21.0)) * 6.2831853 * s
            + 6.2831853 * spark_hash(needle.z, 22.0)));
        float r = size * 0.5 * form.core_mul * (0.15 + 0.85 * s * s) * rough;
        // One screen pixel, whatever the zoom, so the edge is antialiased
        // rather than a hard or a blurry line.
        float main_sd = d - r;
        float aa = max(fwidth(main_sd), 1e-3);
        float spine = spark_core(d, r, aa, segment_len, blur);

        // Older trails acquire one or two soft gaps. Their positions are
        // fixed by the particle seed and their opacity changes continuously,
        // so breakup reads as hot chips rather than flickering dashes.
        float breakup = smoothstep(0.38, 0.92, age);
        float gap_blur = blur / max(segment_len, 1.0);
        float aa_s = max(max(fwidth(s), 1e-4), 0.7 * gap_blur);
        float gap1_c = 0.18 + 0.38 * spark_hash(needle.z, 23.0);
        float gap1_w = 0.016 + 0.026 * spark_hash(needle.z, 24.0);
        float gap1 = smoothstep(gap1_w, gap1_w + 2.0 * aa_s, abs(s - gap1_c));
        float gap1_energy = blur > 0.0 ? gap1_w / sqrt(gap1_w * gap1_w + gap_blur * gap_blur) : 1.0;
        float continuity = 1.0 - breakup * (1.0 - gap1) * gap1_energy
            * (0.55 + 0.25 * spark_hash(needle.z, 25.0));
        if (spark_hash(needle.z, 26.0) > 0.72) {
            float gap2_c = 0.52 + 0.22 * spark_hash(needle.z, 27.0);
            float gap2_w = 0.012 + 0.020 * spark_hash(needle.z, 28.0);
            float gap2 = smoothstep(gap2_w, gap2_w + 2.0 * aa_s, abs(s - gap2_c));
            float gap2_energy = blur > 0.0 ? gap2_w / sqrt(gap2_w * gap2_w + gap_blur * gap_blur) : 1.0;
            continuity *= 1.0 - breakup * 0.62 * (1.0 - gap2) * gap2_energy;
        }
        spine *= continuity;

        // Branches are thinner, dimmer, unequal twigs.
        //
        // They grow in after the initial line rather than being stamped onto
        // every newborn spark, and each gets its own small bloom so it is not
        // a pasted wire.
        float fork_core = 0.0, fork_bloom = 0.0;
        if (form.forked > 1e-4) {
            vec2 rel = vec2(ax - form.fork_x, ay);
            float tp = clamp(dot(rel, form.fork_dir), 0.0, form.fork_len);
            float d2 = length(rel - form.fork_dir * tp);
            float r2 = size * 0.40 * form.core_mul
                * (1.0 - 0.55 * tp / max(form.fork_len, 1e-3));
            float sd2 = d2 - r2;
            float aa2 = max(fwidth(sd2), 1e-3);
            fork_core = max(fork_core, form.forked * 0.76
                * spark_core(d2, r2, aa2, form.fork_len, blur));
            float rb2 = r2 + 0.38 * size;
            fork_bloom = max(fork_bloom, form.forked * 0.42
                * spark_gaussian(d2, rb2, form.fork_len, blur));
        }
        if (form.fork2ed > 1e-4) {
            vec2 rel = vec2(ax - form.fork2_x, ay);
            float tp = clamp(dot(rel, form.fork2_dir), 0.0, form.fork2_len);
            float d2 = length(rel - form.fork2_dir * tp);
            float r2 = size * 0.27 * form.core_mul
                * (1.0 - 0.60 * tp / max(form.fork2_len, 1e-3));
            float sd2 = d2 - r2;
            float aa2 = max(fwidth(sd2), 1e-3);
            fork_core = max(fork_core, form.fork2ed * 0.62
                * spark_core(d2, r2, aa2, form.fork2_len, blur));
            float rb2 = r2 + 0.34 * size;
            fork_bloom = max(fork_bloom, form.fork2ed * 0.34
                * spark_gaussian(d2, rb2, form.fork2_len, blur));
        }
        float core = max(spine, fork_core);
        // A soft bloom hugging the core, and a wider halo that is longer
        // along the streak than across it and widest at the head.
        float rb = r + 0.5 * size;
        float old_haze = smoothstep(0.40, 0.85, age);
        float spine_bloom = spark_gaussian(d, rb, segment_len, blur) * (0.55 + 0.45 * continuity)
                                * mix(1.0, 0.65, old_haze);
        float hd = length(vec2((ax - along) * 0.55, ay));
        float old_halo = mix(1.0, 0.42, old_haze);
        float halo_profile = exp(-hd / (1.4 * size));
        if (blur > 0.0) {
            // The elliptical exponential halo has variance 3 * scale^2.
            // Broaden each axis by the same optical variance and conserve
            // the integral of its finite line plus elliptical end caps.
            float hy = 1.4 * size, hx = hy / 0.55;
            float wy = sqrt(hy * hy + blur * blur / 3.0);
            float wx = sqrt(hx * hx + blur * blur / 3.0);
            float energy = (hy / wy)
                * (segment_len + 3.1415927 * hx) / (segment_len + 3.1415927 * wx);
            halo_profile = exp(-length(vec2((ax - along) / wx, ay / wy))) * energy;
        }
        float halo = halo_profile * glow * (0.3 + 0.7 * s) * old_halo;
        // Per-axis boundary fade uses the analytically padded quad instead
        // of an inscribed ellipse, which used to cut diagonal branches.
        vec2 edge_uv = abs((uv - 0.5) * 2.0);
        float edge = (1.0 - smoothstep(0.88, 1.0, edge_uv.x))
            * (1.0 - smoothstep(0.88, 1.0, edge_uv.y));
        // Along the streak the head is brightest and the tail dims away.
        float head = 0.5 + 0.5 * s;
        float lc = core, lb = spine_bloom * 0.55 + fork_bloom, lh = halo * 0.36;
        float light = clamp((lc + lb + lh) * head * tint.a * edge, 0.0, 1.0);
        // Mix up to 15% white into the thin core of a young spark. Fade that
        // mix out as it ages. Tint the bloom and halo with the glyph color.
        //
        // Keep the light premultiplied (RGB <= alpha) so the blit can
        // unpremultiply it.
        //
        // Convert the normalized sRGB tint to linear before writing it. The
        // layer stores linear light and the final target encodes it. Skipping
        // the conversion would make the spark lighter and paler than the glyph.
        vec3 tint_lin = srgb2linear(tint.rgb);
        float young = (1.0 - age) * (1.0 - age);
        vec3 core_col = mix(tint_lin, srgb2linear(vec3(1.0, 0.98, 0.92)), 0.15 * young);
        vec3 col = (core_col * lc + tint_lin * (lb + lh)) / max(lc + lb + lh, 1e-4);
        // The scene pass blends directly into the final sRGB framebuffer.
        // Encode before premultiplying so translucent RGB stays <= alpha.
        return vec4((output_srgb ? linear2srgb(col) : col) * light, light);
    }
    // Dot tints come directly from the glyph in sRGB.
    if (!output_srgb) tint.rgb = srgb2linear(tint.rgb);
    // The sharp dot keeps its original profile. A world dot uses a Gaussian
    // with the same integrated light and peak; defocusing
    // broadens it and reduces its peak as an area, independently of paper.
    if (needle.w > 0.0) {
        float radius = max(0.5 * needle.x, 1e-3);
        float d_px = length(uv - 0.5) * shape.z;
        float sharp = 1.0 - smoothstep(0.15, 1.0, d_px / radius);
        float width = 0.4282231 * radius;
        float defocused = spark_gaussian(d_px, width, 0.0, needle.w);
        float a = tint.a * mix(sharp, defocused, smoothstep(0.0, width, needle.w));
        return vec4(tint.rgb * a, a);
    }
    // A soft round sprite, so particles read as glowing dots rather than boxes.
    float d = length(uv - 0.5) * 2.0;
    float a = tint.a * (1.0 - smoothstep(0.15, 1.0, d));
    return vec4(tint.rgb * a, a); // premultiplied, as the other effects are
}

