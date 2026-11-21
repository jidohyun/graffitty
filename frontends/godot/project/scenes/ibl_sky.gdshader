shader_type sky;
// Sample the original cube faces from Filament's lightroom_14b_ibl.ktx.
//
// Godot's KTX importer rejects cube maps. Build a Cubemap from six
// Images at runtime so the shader can sample those pixels directly.
uniform samplerCube probe : filter_linear;
uniform float energy = 1.0;

void sky() {
	COLOR = texture(probe, EYEDIR).rgb * energy;
}
