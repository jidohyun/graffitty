shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
vec3 linear_to_srgb(vec3 c) {
 return mix(1.055 * pow(max(c,vec3(0.0)),vec3(1.0/2.4)) - 0.055,12.92*c,lessThanEqual(c,vec3(0.0031308)));
}
void fragment() {
 vec4 ink = texture(TEXTURE,UV);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
 // Compatibility draws 2D in sRGB even into an HDR (use_hdr_2d) viewport.
 COLOR = ink;
#else
 // Match the existing 3D tonemapper, which encodes premultiplied RGB.
 COLOR = vec4(linear_to_srgb(ink.rgb),ink.a);
#endif
}
