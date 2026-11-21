// Each arrival group gets 1.2 seconds, with the last starting 333 ms later.
const float SCATTER_ARRIVAL = 1.2 + 1.0 / 3.0;

// Arrival cruises at the departure's pace, easing to rest over its last 300 ms.
float scatter_flight(float phase) {
	float remaining = clamp(phase, 0.0, 1.0) * 1.2;
	float u = min(remaining / 0.3, 1.0);
	float distance = 0.3 * (u * u * u - 0.5 * u * u * u * u) + max(remaining - 0.3, 0.0);
	return distance / 1.05;
}

// Three random groups, sampled without replacement: 20% now, 60% at 167 ms,
// and the remaining 20% at 333 ms. These are seconds, independent of FPS.
float scatter_release(float rank) {
	if (rank < 0.2) { return 0.0; }
	if (rank < 0.8) { return 1.0 / 6.0; }
	return 1.0 / 3.0;
}

// Begin at 20% speed, then gently reach cruise over 150 ms: no long dwell.
float scatter_departure(float elapsed) {
	float t = clamp(elapsed, 0.0, 1.1);
	float u = min(t / 0.15, 1.0);
	float distance = 0.15 * (u * u * u - 0.5 * u * u * u * u) + max(t - 0.15, 0.0);
	return (0.2 * t + 0.8 * distance) / 1.04;
}

float scatter_clock(float time, float rank, bool arriving) {
	if (arriving) {
		float elapsed = (1.0 - clamp(time, 0.0, 1.0)) * SCATTER_ARRIVAL;
		return scatter_flight((1.2 - elapsed + scatter_release(rank)) / 1.2);
	}
	// Each cohort gets the same gentle lift, measured from its own release.
	return scatter_departure(time * 1.5 - scatter_release(rank));
}

// Carry the incoming velocity instead of accelerating its spring backwards.
float scatter_retire_pose(float position, float velocity, float elapsed) {
	float response = min(0.1, max(position, 0.000001) / max(-velocity, 0.000001) * 0.5);
	float carried = response * (1.0 - exp(-max(elapsed, 0.0) / response));
	return position + velocity * carried + (elapsed - carried) / 1.04;
}

float scatter_retire(float phase, float rank, float elapsed) {
	float position = scatter_clock(phase, rank, true);
	float velocity = (scatter_clock(clamp(phase - 0.0001, 0.0, 1.0), rank, true)
		- scatter_clock(clamp(phase + 0.0001, 0.0, 1.0), rank, true)) / (0.0002 * SCATTER_ARRIVAL);
	return scatter_retire_pose(position, velocity, elapsed);
}

// Opacity is a cleanup behind the eye, after near-plane clipping hides the ink.
float scatter_opacity(float flight) {
	return 1.0 - smoothstep(1.25, 1.5, 1.5 * flight);
}

// Neighbours share a flow: away from the pane centre, with a fixed tie-break
// for its exact centre. Position chooses the path; only tumble varies.
vec2 scatter_escape(vec2 pane_uv) {
	vec2 radial = pane_uv - vec2(0.5);
	if (dot(radial, radial) < 0.000001) { radial = vec2(1.0, 0.0); }
	return normalize(radial);
}

// A broad gust ties neighbours together; fixed per-piece jitter roughens it.
// The tangent bends 30–70 degrees, with a broad upper-left/lower-left fan
// (up to 60 degrees either side of left). No time-varying noise.
vec2 scatter_wind(vec2 sheet_uv, vec2 jitter) {
	vec2 p = sheet_uv - vec2(0.5);
	float gust = sin(p.y * 3.0 + p.x * 1.7);
	float bend = radians(clamp(50.0 + 14.0 * gust + 12.0 * (jitter.x - 0.5), 30.0, 70.0));
	float heading = radians(12.0 * sin(p.x * 2.2 + p.y * 1.4) + 96.0 * (jitter.y - 0.5));
	return vec2(-cos(heading), sin(heading)) * tan(bend);
}

// A small initial tangent can point right before the wind bends it left.
// Vertical drift follows the gust, so a downward path never suddenly turns up.
vec2 scatter_drift(vec2 sheet_uv, vec2 jitter, vec2 wind) {
	float right = 0.02 + 0.06 * (jitter.x - 0.5) + 0.01 * sin((sheet_uv.y - 0.5) * 3.0);
	return vec2(right, 0.045 * wind.y / length(wind));
}

// One continuous arc from release: lateral acceleration grows cubically, with
// no straight segment or turn threshold. The weak early pull preserves the
// close-camera approach; the 30–70 degree wind slope develops behind the eye.
float scatter_wind_distance(float flight) {
	float u = flight / 0.85;
	return 1.5 * 0.85 / 5.0 * u * u * u * u * u;
}

vec3 scatter_travel(float flight, vec2 screen_offset, vec2 wind, vec2 drift, bool arriving) {
	float depth = 1.5 * flight;
	vec2 lateral = drift * flight + wind * scatter_wind_distance(flight);
	// Mirror only the arc; the camera ray still ends at the same character.
	// Retiring arrivals retain this side instead of jumping to a departure path.
	if (arriving) { lateral.x = -lateral.x; }
	return vec3(-screen_offset * depth + lateral, depth);
}

float scatter_spin(float flight, vec3 seeds) {
	float angle = mix(0.5, 1.5, seeds.x) * 6.28318530718;
	return angle * clamp(flight / mix(0.85, 1.0, seeds.y), 0.0, 1.0)
		* (seeds.z < 0.5 ? -1.0 : 1.0);
}
