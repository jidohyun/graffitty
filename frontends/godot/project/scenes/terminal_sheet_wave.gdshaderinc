// Paper wave depth, in isotropic source pixels.
float sheet_depth(vec2 source_uv) {
	vec2 panel_size = max(panel_rect.zw * tex_size, vec2(1.0));
	float short_side = min(panel_size.x, panel_size.y);
	float radius = length((source_uv - cursor) * tex_size);
	float k = TAU / max(ripple_wavelength * short_side, 0.001);
	float falloff_inv = 1.0 / max(ripple_falloff * short_side, 1.0);
	float depth = 0.375 * tan(radians(ripple / max(wave_zoom, 1.0)))
			* sin(radius * k - ripple_phase) * exp(-radius * falloff_inv);
	float sigma = max(0.25 * ripple_wavelength * short_side, 0.001);
	for (int i = 0; i < 8; i++) {
		if (i >= splash_count) { break; }
		vec4 ring = splash_rings[i];
		if (ring.z < 0.0 || ring.z >= splash_life) { continue; }
		float u = length((source_uv - ring.xy) * tex_size) - ring.z * splash_speed;
		float angle = min(ring.w * exp(-3.0 * ring.z / max(splash_life, 0.001)), 45.0);
		depth += 0.375 * tan(radians(angle)) / max(wave_zoom, 0.001)
				* sin(u * 2.0 / sigma) * exp(-u * u / (sigma * sigma));
	}
	return depth;
}

