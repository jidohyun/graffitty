shader_type spatial;
instance uniform float workspace_clip_top = 0.0;
// Animate terminal cells or short text runs as pieces of the painted
// terminal texture. Grouped text gains stroke depth during the transition.
//
// - Each piece is a UV rectangle. A screenful takes one draw call and
//   reuses existing glyph pixels.
// - The shader reads motion from INSTANCE_CUSTOM and uniforms. The CPU
//   writes each instance once, even when the screen crosses the room.
// - Match the live sheet's depth so the lens blurs pieces at the correct
//   distance during handoff.
// - Offset coplanar captures slightly to preserve canvas order while
//   keeping depth tests and writes for the lens.
render_mode unshaded, cull_disabled, blend_mix, shadows_disabled, world_vertex_coords, depth_draw_always;
uniform float stack_depth_bias = 0.0000003;
#include "res://scenes/terminal_defocus.gdshaderinc"
uniform vec3 source_depth_plane = vec3(1.0, 0.0, 0.0);
varying float source_ink_depth;

uniform sampler2D terminal_tex : filter_linear, source_color;
uniform vec2 cell_uv = vec2(0.01, 0.03);   // one cell, in texture uv
uniform bool multirow_cells = false;
uniform bool dust_mode = false;
uniform int dust_count = 0;
uniform vec2 dust_tex_size = vec2(1.0);
#include "dust_motion.gdshaderinc"
uniform float progress = 0.0;              // 0 scattered, 1 assembled
uniform float spread = 7.0;                // start distance, in cell widths
uniform float spin = 5.0;                  // start spin, radians
// Alpha normally follows `progress`, which is right for an arrival: a piece
// fades in as it lands.
//
// A piece that has to be *seen* flying needs the two separated, so >= 0 holds
// the alpha and lets progress govern position alone.
uniform float fade = -1.0;
uniform float ink_gain = 1.0;
uniform float exposure_compensation = 1.0;
uniform bool preserve_flight_opacity = false;
uniform bool retire_flight_pieces = false;
uniform bool panel_layer = false;
uniform bool background_layer = false;
uniform vec4 panel_rect;
uniform vec2 panel_tex_size;
uniform vec4 panel_color : source_color;
uniform float panel_opacity = 0.0;
uniform float panel_radius = 18.0;
uniform float panel_feather = 32.0;
uniform float focus_depth = 1.0;
uniform float blur_radius = 0.0;
uniform float blur_limit = 24.0;
uniform bool screen_dof = false;
varying float piece_depth;
varying float flight_blur;

// Where the screen lives, as the same uv -> world map the wall uses: world =
// origin + u * du + v * dv.
//
// Two of them, because a tab switch moves the screen from one wall to another
// and `travel` slides it across.
//
// With both set to the same plane and travel 0, this is an ordinary shatter
// on one wall.
uniform vec3 plane_a_origin;
uniform vec3 plane_a_du;
uniform vec3 plane_a_dv;
uniform vec3 plane_b_origin;
uniform vec3 plane_b_du;
uniform vec3 plane_b_dv;
uniform float travel = 0.0;

// Send outgoing pieces from the wall toward the viewer.
//
// Vary each piece's start time, speed, and rotation. Carry it just past
// the camera's position at the start of the switch.
uniform vec3 fly_target;
uniform bool grouped_flight = false;
uniform bool chunked_flight = false;
uniform bool arrival_flight = false;
uniform float retirement_time = -1.0;
uniform float retirement_phase = 0.0;
uniform float chunk_seed = 0.0;
uniform float group_index = 0.0;
uniform vec4 group_motion = vec4(0.3, -0.2, 0.2, 0.0);
uniform vec2 group_rotation = vec2(0.1, 0.15);
uniform vec2 group_float = vec2(0.1, 0.0);
uniform vec3 group_travel_du;
uniform vec3 group_travel_dv;
uniform bool camera_relative_flight = false;
uniform mat4 flight_camera_transform;
uniform vec3 flight_camera_eye;
uniform float fly = 0.0;          // 0 still on the wall, 1 everyone has passed
uniform float fly_stagger = 0.45; // how much of that is start times, not travel
uniform float fly_reach = 1.25;   // 1 is exactly the camera; past it is behind you
uniform float fly_tumble = 5.0;   // radians on the way in
uniform float fly_tilt = 2.2;     // and how far it turns out of the wall plane
uniform float fly_arc = 0.18;     // bow of the path, as a fraction of its length
// 1 is a constant speed, which reads as a slide rather than a throw.
//
// Above it the piece leaves the wall gently and is quickest as it goes by —
// and the arrival, which is this run backwards, comes in fast and settles.
uniform float fly_ease = 2.2;
// Grouped text has a continuous alpha volume during flight. Legacy single-quad
// effects approximate thickness by walking the captured stroke mask in UV.
// Thickness is measured in cell heights and disappears at the assembled pose.
uniform float thickness = 0.0;
uniform float thickness_shade = 0.45;

varying vec2 piece_uv;
varying float piece_fade;
varying vec2 piece_extrude;
varying vec4 piece_bounds;
varying vec3 volume_point;
varying vec3 volume_ray;
varying vec3 volume_face;
varying float volume_depth;
#include "piece_sheet_projection.gdshaderinc"
#include "scatter_motion.gdshaderinc"

// Arithmetic-only hash: no random texture, per-frame CPU data, or sine hashes.
vec4 chunk_random(float value) {
	vec4 p = fract(vec4(value) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p += dot(p, p.wzxy + 33.33);
	return fract((p.xxyz + p.yzzw) * p.zywx);
}

vec3 rotate_piece(vec3 value, vec3 axis, float angle) {
	return value * cos(angle) + cross(axis, value) * sin(angle)
		+ axis * dot(axis, value) * (1.0 - cos(angle));
}

// Never borrow a neighbouring run's glyphs when filtering a moving piece.
vec4 sample_piece(vec2 uv) {
	if (chunked_flight) {
		if (any(lessThan(uv, piece_bounds.xy)) || any(greaterThan(uv, piece_bounds.xy + piece_bounds.zw))) { return vec4(0.0); }
		vec2 inset = min(vec2(0.5) / vec2(textureSize(terminal_tex, 0)), piece_bounds.zw * 0.49);
		uv = clamp(uv, piece_bounds.xy + inset, piece_bounds.xy + piece_bounds.zw - inset);
	}
	return textureLod(terminal_tex, uv, 0.0);
}

void vertex() {
	flight_blur = 0.0;
	volume_depth = 0.0;
	volume_point = vec3(0.0);
	volume_ray = vec3(0.0);
	volume_face = vec3(0.0);
	// xy: UV origin; z: extra columns + delay; w: extra rows + seed for text.
	vec2 uv_origin = INSTANCE_CUSTOM.xy;
	float delay = fract(INSTANCE_CUSTOM.z);
	vec2 piece_size = cell_uv * vec2(1.0 + floor(INSTANCE_CUSTOM.z), multirow_cells ? 1.0 + floor(INSTANCE_CUSTOM.w) : 1.0);
	if (dust_mode) { piece_size = INSTANCE_CUSTOM.zw; }
	float seed = multirow_cells ? fract(INSTANCE_CUSTOM.w) : INSTANCE_CUSTOM.w;
	piece_uv = uv_origin + UV * piece_size;
	piece_bounds = vec4(uv_origin, piece_size);

	float local = clamp((progress - delay) / max(1.0 - delay, 1e-3), 0.0, 1.0);
	float eased = 1.0 - pow(1.0 - local, 3.0);
	piece_fade = fade < 0.0 ? eased : fade;
	// Fade by lifetime, not distance past the old camera: navigation can leave
	// that point visible. Reverse playback naturally fades arriving pieces in.
	if (retire_flight_pieces) {
		piece_fade *= 1.0 - smoothstep(0.58 + seed * 0.08, 0.94 + seed * 0.05, fly);
	}

	// The plane this piece is on right now, and the cell's own axes on it: `right`
	// and `down` are exactly one cell, so `spread` stays readable in cells.
	vec3 origin = mix(plane_a_origin, plane_b_origin, travel);
	vec3 du = mix(plane_a_du, plane_b_du, travel);
	vec3 dv = mix(plane_a_dv, plane_b_dv, travel);
	vec3 right = du * piece_size.x;
	vec3 down = dv * piece_size.y;
	vec3 normal = normalize(cross(right, down));
	vec2 centre_uv = uv_origin + piece_size * 0.5;
	vec2 bent_centre = projected_piece_uv(centre_uv);
	vec3 centre = origin + du * bent_centre.x + dv * bent_centre.y;

	vec2 bent_corner = projected_piece_uv(piece_uv);
	source_ink_depth = dot(source_depth_plane, vec3(1.0, source_sheet_rect.xy + bent_corner * source_sheet_rect.zw));
	vec3 assembled = origin + du*bent_corner.x + dv*bent_corner.y;
	vec3 pos = assembled;
	piece_extrude = vec2(0.0);
	if (!grouped_flight) {
	// How far along its own approach this piece is. Its start and its speed come
	// out of its seed, so a layer leaves as a shower rather than a sheet.
	float start = fract(seed * 7.31) * fly_stagger;
	float pace = 0.8 + 0.6 * fract(seed * 3.77);
	float linear = clamp(max(fly - start, 0.0) * pace / max(1.0 - fly_stagger, 1e-3),
			0.0, fly_reach);
	// Eased over the path, not over the clock, so every piece accelerates the
	// same way whenever it happens to start.
	//
	// Past the target the curve continues at the speed it had reached, so
	// nothing kinks as it goes by.
	float ramp = min(linear, 1.0);
	float k = pow(ramp, fly_ease) + max(linear - 1.0, 0.0) * fly_ease;

	// UV (0,0) is the cell's top left, so the corner offset is UV - 0.5 and +down
	// is down the wall.
	vec2 corner = UV - vec2(0.5);
	float turn = (1.0 - eased) * spin * (seed - 0.5) + k * fly_tumble * (seed - 0.5);
	float c = cos(turn);
	float s = sin(turn);
	corner = mat2(vec2(c, -s), vec2(s, c)) * corner;

	// Tilting out of the wall plane is what makes an approaching piece read as a
	// card rather than a sprite: rotate the cell about its own horizontal axis.
	float tilt = k * fly_tilt * (fract(seed * 5.13) - 0.5);
	vec3 offset = right * corner.x + down * (corner.y * cos(tilt))
			+ normal * (length(down) * corner.y * sin(tilt));

	// Two of the three directions are cell sized; the one off the wall is in world
	// units, which is what gives a scattered screen its depth.
	float angle = seed * 6.2831853;
	vec3 direction = right * cos(angle) + down * sin(angle)
			+ normal * (0.35 + 0.65 * fract(seed * 17.13));
	pos = centre + offset + direction * (1.0 - eased) * spread;
	// Preserve the exact assembled corners; release the bend as pieces fly.
	pos += (assembled - (centre + right*(UV.x-0.5) + down*(UV.y-0.5)))
		* (1.0-smoothstep(0.0,0.15,k)) * eased;
	// The approach moves the whole piece, so it keeps its shape on the way in.
	vec3 toward = fly_target - centre;
	float span = length(toward);
	pos += toward * k;
	// ...and bows out of the straight line, in its own direction around that
	// line.
	//
	// Zero at both ends and widest half way, so the path is an arc whichever way
	// it is being travelled.
	//
	// Guarded: with no target set, `toward` is zero and normalising it would put
	// every vertex at NaN — a whole screen of nothing.
	if (span > 1e-5) {
		vec3 axis = toward / span;
		vec3 side = normalize(cross(axis,
				abs(axis.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 lift = cross(axis, side);
		float swing = fract(seed * 11.71) * 6.2831853;
		pos += (side * cos(swing) + lift * sin(swing))
				* sin(k * 3.14159265) * fly_arc * span;
	}
	// Gone as it goes by: a piece behind the camera is not something to look at.
	if (!preserve_flight_opacity) {
		piece_fade *= 1.0 - smoothstep(0.80, 1.08, k);
	}

	// How much of the stroke's side this piece shows: the view direction, taken
	// apart along the cell's own axes. Tilted pieces get a long side, pieces
	// square to the camera get none.
	vec3 view = normalize(pos - CAMERA_POSITION_WORLD);
	piece_extrude = vec2(dot(view, normalize(right)), dot(view, normalize(down)))
			* piece_size * thickness * smoothstep(0.0, 0.2, k);

	if (panel_layer || background_layer) {
		// Backings recede on departure and approach from behind on arrival.
		// The caller restricts the fade to departure start / arrival end.
		float panel_flight = smoothstep(0.0, 1.0, fly);
		float lift = min(span, min(length(du * panel_rect.z), length(dv * panel_rect.w)) * 0.06);
		vec3 drift = span > 1e-5 ? toward / span * lift : vec3(0.0);
		pos = assembled - drift * panel_flight;
		piece_extrude = vec2(0.0);
		piece_fade = 1.0 - panel_flight;
	}
	}
	if (grouped_flight && !dust_mode) {
		// Text uses short rigid runs; other UI uses intact sheets. Each piece
		// preserves its internal spacing, double-width glyphs and artwork.
		vec4 motion = group_motion;
		vec2 rotation = group_rotation;
		vec2 floating = group_float;
		vec3 spin_axis = normal;
		vec3 spin_seeds = vec3(0.0);
		vec2 wind_jitter = fract(vec2(chunk_seed) * vec2(5.13, 13.37));

		if (chunked_flight) {
			vec4 random_a = chunk_random(dot(centre_uv, vec2(127.1, 311.7)));
			vec4 random_b = chunk_random(dot(centre_uv, vec2(127.1, 311.7)) + 19.17);
			vec2 direction = scatter_escape(centre_uv);
			motion = vec4(direction * mix(0.035, 0.085, random_a.z), mix(0.96, 1.06, random_b.w), random_a.w);
			floating = random_b.xy * 0.32 - vec2(0.16);
			// Any 3D axis, including combinations of pitch, yaw and roll.
			spin_axis = normalize(random_b.xyz * 2.0 - vec3(1.0) + vec3(0.00001));
			spin_seeds = vec3(random_b.w, random_a.y, random_b.x);
			wind_jitter = random_b.xy;
		}
		float rank = chunked_flight ? seed : clamp(1.0 - length(source_sheet_rect.xy + source_sheet_rect.zw * 0.5 - vec2(0.5)) * 1.41421356, 0.0, 1.0);
		float flight = retirement_time >= 0.0 ? scatter_retire(retirement_phase, rank, retirement_time) : scatter_clock(fly, rank, arrival_flight);
		vec3 group_centre = chunked_flight ? centre : origin + du * 0.5 + dv * 0.5;
		vec3 axis_x = normalize(du);
		vec3 relative = assembled - group_centre;
		float turn = rotation.x * flight;
		float lean = rotation.y * flight;
		// Rigid rotations, with an exact identity at landing even on a skewed
		// sheet. Random parameters are chosen once per layer by the caller.
		vec3 rotated;
		if (chunked_flight) {
			float angle = scatter_spin(flight, spin_seeds);
			rotated = relative * cos(angle) + cross(spin_axis, relative) * sin(angle)
					+ spin_axis * dot(spin_axis, relative) * (1.0 - cos(angle));
		} else {
			vec3 rolled = relative * cos(turn) + cross(normal, relative) * sin(turn)
					+ normal * dot(normal, relative) * (1.0 - cos(turn));
			rotated = rolled * cos(lean) + cross(axis_x, rolled) * sin(lean)
					+ axis_x * dot(axis_x, rolled) * (1.0 - cos(lean));
		}
		vec3 eye = camera_relative_flight ? flight_camera_eye : CAMERA_POSITION_WORLD;
		mat3 camera_axes = mat3(INV_VIEW_MATRIX);
		if (camera_relative_flight) { camera_axes = transpose(mat3(flight_camera_transform)) * camera_axes; }
		vec3 camera_centre = transpose(camera_axes) * (group_centre - eye);
		float depth = max(-camera_centre.z, 0.00001);
		vec2 sheet_uv = source_sheet_rect.xy + (chunked_flight ? centre_uv : vec2(0.5)) * source_sheet_rect.zw;
		vec2 wind = scatter_wind(sheet_uv, wind_jitter);
		vec2 drift = scatter_drift(sheet_uv, wind_jitter, wind);
		vec3 displacement = scatter_travel(flight, camera_centre.xy * vec2(1.0, -1.0) / depth, wind, drift, arrival_flight);
		pos = assembled + (rotated - relative) + camera_axes * (displacement * vec3(1.0, -1.0, 1.0) * depth);
		// Keep full ink coverage through the camera crossing.
		piece_fade = scatter_opacity(flight);
		flight_blur = flight * 2.0;
		piece_extrude = vec2(0.0);
		if (chunked_flight) {
			float volume = smoothstep(0.0, 0.06, flight);
			float angle = scatter_spin(flight, spin_seeds);
			vec3 spun_normal = rotate_piece(normal, spin_axis, angle);
			vec3 spun_right = rotate_piece(normalize(right), spin_axis, angle);
			vec3 spun_down = rotate_piece(normalize(down), spin_axis, angle);
			volume_depth = length(down) * thickness * volume;
			pos += spun_normal * volume_depth * (UV2.x - 0.5);
			vec3 ray = pos - eye;
			volume_point = vec3(UV, UV2.x);
			volume_ray = vec3(dot(ray, spun_right) / max(length(right), 0.000001),
				dot(ray, spun_down) / max(length(down), 0.000001),
				dot(ray, spun_normal) / max(volume_depth, 0.000001));
			volume_face = UV2.y < 0.5 ? vec3(0,0,-1) : (UV2.y < 1.5 ? vec3(0,0,1)
				: (UV2.y < 2.5 ? vec3(-1,0,0) : (UV2.y < 3.5 ? vec3(1,0,0)
				: (UV2.y < 4.5 ? vec3(0,-1,0) : vec3(0,1,0)))));
			if (volume_depth <= 0.000001 && UV2.y > 0.5) { piece_fade = 0.0; }
		}
	}

	if (dust_mode) {
		float flight = retirement_time >= 0.0 ? scatter_retire(retirement_phase, COLOR.r, retirement_time) : scatter_clock(fly, COLOR.r, arrival_flight);
		float random = dust_hash(centre_uv * dust_tex_size);
		vec3 eye = camera_relative_flight ? flight_camera_eye : CAMERA_POSITION_WORLD;
		mat3 axes = mat3(INV_VIEW_MATRIX);
		if (camera_relative_flight) { axes = transpose(mat3(flight_camera_transform)) * axes; }
		vec3 eye_centre = transpose(axes) * (centre - eye);
		float depth = max(-eye_centre.z, 0.00001);
		vec2 sheet_uv = source_sheet_rect.xy + centre_uv * source_sheet_rect.zw;
		vec2 jitter = vec2(0.5) + (vec2(random, fract(random * 13.7)) - 0.5) * 0.16;
		vec2 wind = scatter_wind(sheet_uv, jitter);
		vec3 displacement = scatter_travel(flight, eye_centre.xy * vec2(1.0,-1.0) / depth, wind, scatter_drift(sheet_uv, jitter, wind), arrival_flight);
		displacement.xy += dust_turbulence(flight, random) * vec2(arrival_flight ? -1.0 : 1.0, 1.0);
		float angle = flight * (random - 0.5) * 2.4;
		// Keep dust fine as it approaches the eye, instead of inflating into slabs.
		vec3 relative = (assembled - centre) * max(0.015, 1.0 - 1.5 * flight);
		pos = centre + relative * cos(angle) + cross(normal, relative) * sin(angle) + normal * dot(normal, relative) * (1.0 - cos(angle));
		pos += axes * (displacement * vec3(1.0,-1.0,1.0) * depth);
		piece_extrude = vec2(0.0);
		volume_depth = 0.0;
		flight_blur = 0.0;
		piece_fade = scatter_opacity(flight) * (1.0 - smoothstep(0.35, 0.85, flight));
	}

	if (camera_relative_flight) {
		pos = (flight_camera_transform * vec4(pos, 1.0)).xyz;
		normal = normalize((flight_camera_transform * vec4(normal, 0.0)).xyz);
	}
	VERTEX = pos;
	piece_depth = -(VIEW_MATRIX * vec4(pos, 1.0)).z;
	NORMAL = normal;
}

void fragment() {
	// Adjacent fragments must still participate when measuring the blur footprint.
	vec2 screen_dx = dFdx(piece_uv);
	vec2 screen_dy = dFdy(piece_uv);
	DEPTH = clamp(FRAGCOORD.z + stack_depth_bias, 0.0, 1.0);
	if (piece_fade <= 0.0001) { discard; }
	if (SCREEN_UV.y < workspace_clip_top) { discard; }
	if (panel_layer) {
		vec2 half_size = panel_rect.zw * panel_tex_size * 0.5;
		vec2 centre = panel_rect.xy + panel_rect.zw * 0.5;
		float r = min(panel_radius, min(half_size.x, half_size.y));
		vec2 q = abs((piece_uv - centre) * panel_tex_size) - half_size + vec2(r);
		float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
		ALBEDO = panel_color.rgb / max(exposure_compensation, 0.0001);
		ALPHA = panel_opacity * (1.0 - smoothstep(-max(panel_feather, 1.5), 0.0, d)) * piece_fade;
	} else {
	vec4 ink = sample_piece(piece_uv);
	float shade = 1.0;
	if (volume_depth > 0.000001) {
		// A convex prism has one entry face per pixel. Discard its exit faces
		// and trace the stroke once, producing a continuous solid silhouette.
		if (dot(volume_ray, volume_face) >= 0.0) { discard; }
		vec3 safe_ray = mix(vec3(-1.0), vec3(1.0), greaterThanEqual(volume_ray, vec3(0.0))) * max(abs(volume_ray), vec3(0.000001));
		vec3 limits = (mix(vec3(0.0), vec3(1.0), greaterThan(volume_ray, vec3(0.0))) - volume_point) / safe_ray;
		float distance = max(0.0, min(limits.x, min(limits.y, limits.z)));
		ink = vec4(0.0);
		for (int i = 0; i <= 16; i++) {
			vec3 at = volume_point + volume_ray * distance * (float(i) / 16.0);
			vec4 candidate = sample_piece(piece_bounds.xy + clamp(at.xy, vec2(0.0), vec2(1.0)) * piece_bounds.zw);
			if (candidate.a > ink.a) {
				ink = candidate;
				shade = i == 0 && abs(volume_face.z) > 0.5 ? 1.0 : 0.55;
			}
			if (ink.a >= 0.9) { break; }
		}
	}
	float radius = dust_mode ? 0.0 : min(blur_limit, max(flight_blur, abs(1.0 - focus_depth / max(piece_depth, 0.01)) * blur_radius));
	if (!screen_dof && radius > 0.45 && volume_depth <= 0.000001) {
		vec4 sum = vec4(0.0);
		float weight_sum = 0.0;
		for (int y = -2; y <= 2; y++) {
			for (int x = -2; x <= 2; x++) {
				vec2 offset = vec2(float(x), float(y)) * 0.5;
				float weight = exp(-3.0 * dot(offset, offset));
				sum += sample_piece(piece_uv + (screen_dx * offset.x + screen_dy * offset.y) * radius) * weight;
				weight_sum += weight;
			}
		}
		ink = mix(ink, sum / weight_sum, smoothstep(0.45, 1.25, radius));
	}

	vec4 side = vec4(0.0);
	if (thickness > 0.0 && !grouped_flight) {
		// Three taps back along the view: the union of them is the stroke seen
		// from the side. More taps buy nothing at a cell this size.
		for (int i = 1; i <= 3; i++) {
			side = max(side, texture(terminal_tex,
					piece_uv + piece_extrude * (float(i) / 3.0)));
		}
	}
	// The terminal's texture is premultiplied; undo it so blend_mix multiplies
	// exactly once, the same rule terminal_sheet.gdshader follows.
	vec3 face = ink.rgb / max(ink.a, 1e-4);
	vec3 flank = side.rgb / max(side.a, 1e-4) * thickness_shade;
	float a = max(ink.a, side.a);
	// The face covers the side wherever it is opaque, so the two never mix into
	// a halo: this is a solid with a lit front and a shaded edge.
	ALBEDO = mix(flank, face, ink.a / max(a, 1e-4))
			* terminal_defocus_gain(source_ink_depth) * ink_gain * shade / max(exposure_compensation, 1e-4);
	ALPHA = a * piece_fade;
	}
	// Retired pieces and transparent cell margins must not leave an invisible
	// depth occluder in front of the arriving terminal.
	if (ALPHA <= 0.0001) {
		discard;
	}
}
