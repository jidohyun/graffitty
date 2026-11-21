// Stable fragment identity, coherent wind and restrained analytic turbulence.
// No changing noise seed, full-frame dissolve, sprite cloud or CPU simulation.
float dust_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 dust_turbulence(float flight, float seed) {
 float t = max(flight, 0.0);
 float drag = 1.0 - exp(-2.5 * t);
 vec2 phase = vec2(seed * 6.2831853, seed * 17.1);
 vec2 curl = sin(phase + vec2(2.4, 1.7) * t) - sin(phase);
 return curl * drag * 0.012 + vec2((seed - 0.5) * 0.009 * drag, 0.004 * t * t);
}
