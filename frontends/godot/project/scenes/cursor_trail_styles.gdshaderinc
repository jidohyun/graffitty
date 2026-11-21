// Cursor effects adapted from Kitty's custom cursor-trail shaders.
// Copyright (C) 2026 Kovid Goyal. Distributed under GPLv3.
// Blaze originally by chardskarth:
// https://gist.github.com/chardskarth/95874c54e29da6b5a36ab7b50ae2d088
uniform int trail_style = 0;
uniform vec2 cell_pixels = vec2(1.0);
uniform vec4 previous_rect;
uniform vec4 target_rect;
uniform float effect_age = 0.0;
uniform float event_seed = 0.0;
uniform float effect_duration = 0.5;
uniform vec4 effect_color : source_color = vec4(1.0, 0.725, 0.161, 1.0);
uniform vec4 effect_accent_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform vec4 effect_glow_color : source_color = vec4(0.74, 0.0, 0.0, 1.0);
uniform float effect_jaggedness = 0.085;
uniform float effect_core_width = 1.15;
uniform float effect_glow_width = 5.5;
vec4 trail_edges(vec4 r) { return vec4(r.x, r.x + r.z, -r.y, -r.y - r.w); }

// pow(1 - x, 10) via repeated squaring — branchless ease-out.
float
ease_out10(float x) {
    float y = 1.0 - x;
    float y2 = y * y;
    float y4 = y2 * y2;
    return y4 * y4 * y2;
}

// Smooth blend curve for the progress value.
float
blend_smooth(float t) {
    float s = t * t;
    return s / (2.0 * (s - t) + 1.0);
}

// SDF of an axis-aligned box.  p = query point, center = box centre, hext = half-extents.
float
sdBox(vec2 p, vec2 center, vec2 hext) {
    vec2 d = abs(p - center) - hext;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

// Single edge contribution for the quadrilateral SDF (signed winding accumulation).
float
seg(vec2 p, vec2 a, vec2 b, inout float s, float d) {
    vec2 e = b - a;
    vec2 w = p - a;
    vec2 proj = a + e * clamp(dot(w, e) / max(dot(e, e), 1e-7), 0.0, 1.0);
    d = min(d, dot(p - proj, p - proj));

    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    s *= mix(1.0, -1.0, step(0.5, allCond + noneCond));
    return d;
}

// SDF of an arbitrary quadrilateral (uses winding number via four edge contributions).
float
sdQuad(vec2 p, vec2 v0, vec2 v1, vec2 v2, vec2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);
    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);
    return s * sqrt(d);
}

// Returns 0 for diagonal movement (up-left / down-right), 1 otherwise.
// Selects which corner of the parallelogram aligns with the movement direction.
float
movementVertexFactor(vec2 a, vec2 b) {
    float c1 = step(b.x, a.x) * step(a.y, b.y);
    float c2 = step(a.x, b.x) * step(b.y, a.y);
    return 1.0 - max(c1, c2);
}

vec4
blaze_trail(vec2 p) {
    vec4 color = vec4(0.0);
    vec4 current_edge = trail_edges(target_rect);
    vec4 previous_edge = trail_edges(previous_rect);
    

    float age = clamp((effect_age) / effect_duration, 0.0, 1.0);
    if (age >= 1.0) return color;

    float easedProgress = ease_out10(blend_smooth(age));
    if (easedProgress <= 0.0) return color;

    // Work in pixel space for correct aspect-ratio distance measurements.
    vec2 pixelDims = cell_pixels;
    vec2 px = p * pixelDims;

    // Current cursor rect in pixel space (edge: .x=left .y=right .z=top .w=bottom, y-up).
    float curLeft = current_edge.x * pixelDims.x;
    float curRight = current_edge.y * pixelDims.x;
    float curTop = current_edge.z * pixelDims.y;
    float curBottom = current_edge.w * pixelDims.y;
    float curWidth = curRight - curLeft;
    float curHeight = curTop - curBottom;
    vec2 curCenter = vec2((curLeft + curRight) * 0.5, (curTop + curBottom) * 0.5);

    float prevLeft = previous_edge.x * pixelDims.x;
    float prevTop = previous_edge.z * pixelDims.y;
    float prevBottom = previous_edge.w * pixelDims.y;
    vec2 prevCenter = vec2(
        (previous_edge.x + previous_edge.y) * 0.5 * pixelDims.x,
        (previous_edge.z + previous_edge.w) * 0.5 * pixelDims.y);

    float lineLength = length(curCenter - prevCenter);
    // Alpha fades to 0 at the previous-cursor end, reaching full effect at the current cursor.
    float alphaModifier = min(length(px - curCenter) / max(lineLength * easedProgress, 1e-7), 1.0);

    // Build parallelogram vertices in pixel space.
    float vf = movementVertexFactor(curCenter, prevCenter);
    float ivf = 1.0 - vf;
    vec2 v0 = vec2(mix(curLeft, curRight, vf), curBottom);
    vec2 v1 = vec2(mix(curLeft, curRight, ivf), curTop);
    vec2 v2 = vec2(prevLeft + curWidth * ivf, prevTop);
    vec2 v3 = vec2(prevLeft + curWidth * vf, prevBottom);

    float sdfCursor = sdBox(px, curCenter, vec2(curWidth, curHeight) * 0.5);
    float sdfTrail = sdQuad(px, v0, v1, v2, v3);

    // ~2-pixel anti-aliasing range in pixel space.
    float aaRange = 2.0;
    vec4 newColor = color;
    // Inner border accent (red-orange inside the trail edges).
    newColor = mix(newColor, effect_accent_color, 1.0 - smoothstep(-aaRange, aaRange * 0.05, sdfTrail));
    // Main amber fill.
    newColor = mix(newColor, effect_color, 1.0 - smoothstep(0.0, aaRange, sdfTrail));
    // Fade: effect is weakest toward the previous cursor end.
    newColor = mix(color, newColor, 1.0 - alphaModifier);
    // Restore original pixels inside the cursor rectangle.
    return mix(newColor, color, step(sdfCursor, 0.0));
}

float
hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float
segDist(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-7), 0.0, 1.0);
    return length(p - (a + ab * t));
}

// A point on the piecewise-linear bolt.  Endpoints stay fixed; interior nodes
// are displaced perpendicular to the travel direction.
vec2
boltPoint(vec2 a, vec2 b, float t, float seed) {
    vec2 delta = b - a;
    float boltLength = length(delta);
    vec2 perp = vec2(-delta.y, delta.x) / max(boltLength, 1e-5);
    float node = floor(t * float(12) + 0.5);
    float rnd = hash11(node * 17.17 + seed) * 2.0 - 1.0;
    float fade = sin(3.14159265 * t);
    return mix(a, b, t) + perp * rnd * boltLength * effect_jaggedness * fade;
}

// Minimum distance from p to the main bolt's piecewise-linear path.
float
mainBoltDist(vec2 p, vec2 a, vec2 b, float seed) {
    float minD = 1e5;
    vec2 prev = a;
    
    for (int i = 1; i <= 12; i++) {
        float t = float(i) / float(12);
        vec2 cur = boltPoint(a, b, t, seed);
        minD = min(minD, segDist(p, prev, cur));
        prev = cur;
    }
    return minD;
}

// Three small forks growing out of alternating points on the main bolt.
float
forkDist(vec2 p, vec2 a, vec2 b, float seed) {
    float minD = 1e5;
    vec2 delta = b - a;
    float boltLength = length(delta);
    vec2 perp = vec2(-delta.y, delta.x) / max(boltLength, 1e-5);
    vec2 dir = delta / max(boltLength, 1e-5);

    
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float t = 0.28 + fi * 0.22;
        vec2 root = boltPoint(a, b, t, seed);
        float side = mix(-1.0, 1.0, step(0.5, hash11(seed + fi * 41.0)));
        float reach = boltLength * (0.055 + 0.035 * hash11(seed + fi * 53.0));
        vec2 along = dir * reach * (hash11(seed + fi * 67.0) - 0.35);
        vec2 tip = root + perp * side * reach + along;
        vec2 elbow = mix(root, tip, 0.52) - perp * side * reach * (0.12 + 0.18 * hash11(seed + fi * 79.0));
        minD = min(minD, segDist(p, root, elbow));
        minD = min(minD, segDist(p, elbow, tip));
    }
    return minD;
}

vec4
lightning_trail(vec2 p) {
    vec4 color = vec4(0.0);
    vec4 current_edge = trail_edges(target_rect);
    vec4 previous_edge = trail_edges(previous_rect);
    float age = clamp((effect_age) / effect_duration, 0.0, 1.0);
    if (age >= 1.0) return color;

    vec2 pixelDims = cell_pixels;

    // Cursor centres in pixel space (edge: .x=left .y=right .z=top .w=bottom, y-up).
    vec2 curCenter = vec2((current_edge.x + current_edge.y) * 0.5, (current_edge.z + current_edge.w) * 0.5) * pixelDims;
    vec2 prevCenter =
        vec2((previous_edge.x + previous_edge.y) * 0.5, (previous_edge.z + previous_edge.w) * 0.5) * pixelDims;

    float cursorWidth = (current_edge.y - current_edge.x) * pixelDims.x;

    vec2 px = p * pixelDims;

    // Quantise the event time for a stable bolt shape across the bolt's lifetime.
    float seed = event_seed * 0.013;

    float mainD = mainBoltDist(px, prevCenter, curCenter, seed);
    float forkD = forkDist(px, prevCenter, curCenter, seed);

    float pixel = max(fwidth(mainD), 0.65);
    float core = 1.0 - smoothstep(effect_core_width, effect_core_width + pixel, mainD);
    float forkCore = 1.0 - smoothstep(effect_core_width * 0.72, effect_core_width * 0.72 + pixel, forkD);
    float glow = exp(-mainD * mainD / (effect_glow_width * effect_glow_width));
    float forkGlow = exp(-forkD * forkD / (effect_glow_width * effect_glow_width * 0.55));

    // Flash hard, then rapidly lose the core, leaving only glow.
    float flash = 1.0 - smoothstep(0.0, 1.0, age);
    flash *= flash;
    float flicker = 0.82 + 0.18 * sin(age * 95.0 + seed);
    float glowAmt = max(glow, forkGlow * 0.55) * flash * flicker * 0.72;
    float coreAmt = max(core, forkCore * 0.82) * flash * flicker;

    vec3 rgb = mix(color.rgb, effect_glow_color.rgb, clamp(glowAmt, 0.0, 1.0));
    rgb = mix(rgb, effect_color.rgb, clamp(coreAmt, 0.0, 1.0));

    // Keep the cursor crisp above the effect.
    float insideCursor = step(current_edge.x, p.x) * step(p.x, current_edge.y) * step(current_edge.w, p.y) *
                         step(p.y, current_edge.z);
    rgb = mix(rgb, color.rgb, insideCursor);

    float alpha = (coreAmt + glowAmt * (1.0 - coreAmt)) * (1.0 - insideCursor);
    return vec4(rgb, alpha);
}

vec4 cursor_trail_ink(vec2 uv, vec4 tint) {
    if (all(greaterThanEqual(uv, cursor_rect.xy)) && all(lessThanEqual(uv, cursor_rect.xy + cursor_rect.zw))) return vec4(0.0);
    if (trail_style == 0) return tint;
    vec2 p = vec2(uv.x, -uv.y);
    vec4 ink = trail_style == 1 ? blaze_trail(p) : lightning_trail(p);
    // Effect functions composite onto transparent black; Godot expects straight alpha.
    if (ink.a > 0.00001) ink.rgb /= ink.a;
    return ink;
}
