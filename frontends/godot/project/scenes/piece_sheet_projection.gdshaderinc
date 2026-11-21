// The forward map of terminal_sheet.gdshader's inverse texture lookup.
// A transition's assembled glyph must occupy the same bent-sheet position.
uniform vec4 source_sheet_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 source_sheet_size = vec2(1.0);
uniform float source_curvature = 0.0;
uniform float source_ripple = 0.0;
uniform float source_wavelength = 0.35;
uniform float source_falloff = 0.3;
uniform float source_phase = 0.0;
uniform float source_zoom = 1.0;
uniform vec2 source_cursor = vec2(0.5);
uniform vec4 source_splashes[8];
uniform int source_splash_count = 0;
uniform float source_splash_life = 0.7;
uniform float source_splash_speed = 600.0;

vec2 projected_piece_uv(vec2 uv) {
	vec2 source = source_sheet_rect.xy + uv * source_sheet_rect.zw;
	float short_side = min(source_sheet_size.x,source_sheet_size.y);
	float radius = length((source-source_cursor)*source_sheet_size);
	float k = TAU / max(source_wavelength*short_side,0.001);
	float depth = 0.375*tan(radians(source_ripple/max(source_zoom,1.0)))
		*sin(radius*k-source_phase)*exp(-radius/max(source_falloff*short_side,1.0));
	float sigma = max(0.25*source_wavelength*short_side,0.001);
	for (int i=0;i<8;i++) {
		if (i>=source_splash_count) { break; }
		vec4 ring=source_splashes[i];
		if (ring.z<0.0 || ring.z>=source_splash_life) { continue; }
		float u=length((source-ring.xy)*source_sheet_size)-ring.z*source_splash_speed;
		float angle=min(ring.w*exp(-3.0*ring.z/max(source_splash_life,0.001)),45.0);
		depth+=0.375*tan(radians(angle))/max(source_zoom,0.001)
			*sin(u*2.0/sigma)*exp(-u*u/(sigma*sigma));
	}
	source=vec2(0.5)+(source-vec2(0.5))/max(1.0+depth,0.001);
	vec2 p=(source-vec2(0.5))*source_sheet_size*vec2(1.0,-1.0);
	float extent=max(source_sheet_size.x,source_sheet_size.y);
	float coefficient=tan(source_curvature)*2.5/max(extent*extent,0.001);
	float fit=1.0/max(1.0-abs(coefficient*source_sheet_size.x*source_sheet_size.y*0.25),0.05);
	source=vec2(0.5)+p*vec2(1.0,-1.0)/(max((1.0+coefficient*p.x*p.y)*fit,0.001)*source_sheet_size);
	return (source-source_sheet_rect.xy)/source_sheet_rect.zw;
}
