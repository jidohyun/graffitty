extends CompositorEffect
## Source-footprint depth of field for linear premultiplied transparent ink.
const CODE := """
#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_image;
layout(set=0,binding=1) uniform sampler2D depth_image;
layout(rgba16f,set=0,binding=2) uniform writeonly image2D destination;
layout(set=0,binding=3) uniform sampler2D source_footprint;
layout(rgba16f,set=0,binding=4) uniform image2D destination_footprint;
layout(push_constant,std430) uniform Params {
    mat4 inverse_projection;
    vec4 lens; // focus, radius, relative depth range, pass (-1=footprint, 0=x, 1=y, 2=resolve)
    vec4 raster; // width, height, blur limit, minimum radius
    vec4 band; // previous radius, current radius, next radius, band index
} p;
const int MAX_RADIUS = 24;
float kernel(float offset, float radius) {
    if (radius <= .45) return offset == 0. ? 1. : 0.;
    float t = abs(offset) / radius;
    return exp(-3. * t * t) * (1. - smoothstep(.85, 1., t));
}
float inverse_normalization(float radius) {
    float normalization=1.;
    for(int i=1;i<=MAX_RADIUS;i++) {
        if(float(i)>=radius)break;
        normalization+=2.*kernel(float(i),radius);
    }
    return 1./normalization;
}
void main() {
    ivec2 pixel=ivec2(gl_GlobalInvocationID.xy), size=ivec2(p.raster.xy);
    if(any(greaterThanEqual(pixel,size)))return;
    if (p.lens.w < -.5) {
        float alpha=texelFetch(source_image,pixel,0).a;
        float radius=0.;
        if (alpha > .000001) {
            vec2 uv=(vec2(pixel)+.5)/p.raster.xy;
            float z=texelFetch(depth_image,pixel,0).r;
            vec4 v=p.inverse_projection*vec4(uv*2.-1.,z,1.);
            float d=max(-v.z/v.w,.001);
            radius=min(min(p.raster.z,float(MAX_RADIUS)),max(p.raster.w,
                abs(1.-p.lens.x/d)*p.lens.y/max(p.lens.z,.001)));
        }
        imageStore(destination_footprint,pixel,vec4(radius,inverse_normalization(radius),0,0));
        return;
    }
    if (p.lens.w > 1.5) {
        vec4 ink=imageLoad(destination_footprint,pixel);
        imageStore(destination,pixel,ink/max(1.,ink.a));
        return;
    }
    // Interpolate each source between fixed-radius bands. Filtering each band
    // separately keeps both axes isotropic even where different depths overlap.
    ivec2 axis=p.lens.w<.5?ivec2(1,0):ivec2(0,1);
    vec4 sum=vec4(0.);
    int reach=int(ceil(p.band.y));
    float normalization=inverse_normalization(p.band.y);
    for(int i=-reach;i<=reach;i++) {
        ivec2 q=pixel+axis*i;
        if(any(lessThan(q,ivec2(0)))||any(greaterThanEqual(q,size)))continue;
        float weight=kernel(float(i),p.band.y)*normalization;
        if(p.lens.w<.5) {
            float radius=texelFetch(source_footprint,q,0).x;
            float fraction=radius<=p.band.y
                ? (p.band.y==p.band.x?1.:clamp((radius-p.band.x)/(p.band.y-p.band.x),0.,1.))
                : (p.band.z==p.band.y?1.:clamp((p.band.z-radius)/(p.band.z-p.band.y),0.,1.));
            weight*=fraction;
        }
        if(weight>0.)sum+=texelFetch(source_image,q,0)*weight;
    }
    if(p.lens.w<.5)imageStore(destination,pixel,sum);
    else {
        if(p.band.w>0.)sum+=imageLoad(destination_footprint,pixel);
        imageStore(destination_footprint,pixel,sum);
    }
}
"""
var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var sampler := RID()
var temporary := RID()
var footprints: Array[RID] = []
var texture_size := Vector2i.ZERO
var mutex := Mutex.new()
var lens := Vector4(1, 0, 1, 24)
var minimum_radius := 0.0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()


func set_lens(focus: float, radius: float, depth_range: float, blur_limit: float = 24.0, minimum: float = 0.0) -> void:
	mutex.lock()
	lens = Vector4(focus, radius, depth_range, maxf(blur_limit, 0.0))
	minimum_radius = minimum
	mutex.unlock()


func presentation_copy() -> CompositorEffect:
	var copy := get_script().new() as CompositorEffect
	mutex.lock()
	copy.set_lens(lens.x, lens.y, lens.z, lens.w, minimum_radius)
	mutex.unlock()
	return copy


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for resource in [shader, sampler, temporary] + footprints:
			if resource.is_valid():
				rd.free_rid(resource)


func _render_callback(kind: int, data: RenderData) -> void:
	if rd == null or kind != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	mutex.lock()
	var parameters := lens
	var minimum := minimum_radius
	mutex.unlock()
	if (parameters.y <= 0 and minimum <= 0) or parameters.w <= 0:
		return
	var buffers: RenderSceneBuffersRD = data.get_render_scene_buffers()
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	if not shader.is_valid():
		var source := RDShaderSource.new()
		source.source_compute = CODE
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			return
		shader = rd.shader_create_from_spirv(spirv)
		pipeline = rd.compute_pipeline_create(shader)
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler = rd.sampler_create(state)
	if texture_size != size:
		for resource in [temporary] + footprints:
			if resource.is_valid(): rd.free_rid(resource)
		footprints.clear()
		var format := RDTextureFormat.new()
		format.width = size.x
		format.height = size.y
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		temporary = rd.texture_create(format, RDTextureView.new())
		for i in 2: footprints.append(rd.texture_create(format, RDTextureView.new()))
		texture_size = size
	var inverse: Projection = data.get_render_scene_data().get_cam_projection().inverse()
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		# Radius map, five independent horizontal/vertical bands, then resolve.
		# The second scratch image accumulates premultiplied coverage across bands.
		var radii := [0.0, 3.0, 6.0, 12.0, 24.0]
		for step in 12:
			var axis := -1 if step == 0 else (2 if step == 11 else (step - 1) % 2)
			var band_index := clampi((step - 1) / 2, 0, 4)
			var uniforms: Array[RDUniform] = []
			var textures := [color if axis <= 0 else temporary, depth,
				temporary if axis <= 0 else color,
				# The radius pass writes footprints[0]. One texture cannot be sampled and
				# written in the same dispatch, so that pass binds the other as its unused input.
				footprints[1] if axis == -1 else footprints[0],
				footprints[0] if axis == -1 else footprints[1]]
			for binding in textures.size():
				var uniform := RDUniform.new()
				uniform.binding = binding
				var storage := binding in [2, 4]
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if storage else RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				if not storage: uniform.add_id(sampler)
				uniform.add_id(textures[binding])
				uniforms.append(uniform)
			var constants := PackedFloat32Array()
			for column in [inverse.x, inverse.y, inverse.z, inverse.w]:
				constants.append_array([column.x, column.y, column.z, column.w])
			constants.append_array(
				[
					parameters.x,
					parameters.y,
					parameters.z,
					float(axis),
					float(size.x),
					float(size.y),
					parameters.w,
					minimum,
				]
			)
			constants.append_array([radii[maxi(band_index - 1, 0)], radii[band_index], radii[mini(band_index + 1, 4)], float(band_index)])
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(
				list,
				UniformSetCacheRD.get_cache(shader, 0, uniforms),
				0,
			)
			rd.compute_list_set_push_constant(list, constants.to_byte_array(), constants.size() * 4)
			rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
			rd.compute_list_end()
