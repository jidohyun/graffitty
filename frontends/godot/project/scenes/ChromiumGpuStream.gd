extends RefCounted
## Frame pixels remain on the GPU. Linux reads four completion bytes per frame.
var texture := Texture2DRD.new()
var receiver: RefCounted
var endpoint := ""
var _mutex := Mutex.new()
var _pending := false
var _closed := false
var _frames := 0
var _proof_ready := false
var _error := ""
var _rid := RID()
var _conversion_shader := RID()
var _conversion_pipeline := RID()
var _conversion_sampler := RID()
var _linux_completions: Dictionary = { }
## Set by the session for a page drawn beneath the canvas: a frame of the
## current size waits for publish() at frame_pre_draw (RenderUpdates.before_draw).
var defer_publish := false
## The imported frame awaiting publish(); render thread only.
var _unpublished := RID()
var _holding := false
const CONVERSION_SHADER := """#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0, binding=0) uniform sampler2D source_frame;
layout(rgba8, set=0, binding=1) uniform writeonly image2D destination_frame;
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, imageSize(destination_frame)))) return;
    imageStore(destination_frame, pixel, texelFetch(source_frame, pixel, 0));
}
"""
const LINUX_SHADER := """#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(buffer_reference, std430, buffer_reference_align=4) readonly buffer Source { uint pixels[]; };
layout(push_constant, std430) uniform Params { uvec2 address; uint width; uint bgra; } params;
layout(rgba8, set=0, binding=0) uniform writeonly image2D destination_frame;
layout(std430, set=0, binding=1) writeonly buffer Completion { uint done; } completion;
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, imageSize(destination_frame)))) return;
    vec4 color = unpackUnorm4x8(Source(params.address).pixels[uint(pixel.y) * params.width + uint(pixel.x)]);
    imageStore(destination_frame, pixel, params.bgra != 0 ? color.bgra : color);
    if (all(equal(pixel, ivec2(0)))) completion.done = 1;
}
"""


func _linux_copy_done(
	_data: PackedByteArray,
	keeper: RefCounted,
	sequence: int,
	done: RID,
	_stream: RefCounted,
) -> void:
	RenderingServer.call_on_render_thread(_linux_release_frame.bind(keeper, sequence, done, self))


func _linux_release_frame(
	keeper: RefCounted,
	sequence: int,
	done: RID,
	_stream: RefCounted,
) -> void:
	if not _linux_completions.has(sequence):
		return
	_linux_completions.erase(sequence)
	RenderingServer.get_rendering_device().free_rid(done)
	keeper.release_frame(sequence)


func _convert_linux_frame(rd: RenderingDevice, frame: Dictionary) -> RID:
	if not _conversion_shader.is_valid():
		var code := RDShaderSource.new()
		code.source_compute = LINUX_SHADER
		_conversion_shader = rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(code))
		if _conversion_shader.is_valid():
			_conversion_pipeline = rd.compute_pipeline_create(_conversion_shader)
	if not _conversion_pipeline.is_valid():
		receiver.release_frame(frame.sequence)
		return RID()
	var description := RDTextureFormat.new()
	description.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	description.width = frame.width
	description.height = frame.height
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	description.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	description.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	var owned := rd.texture_create(description, RDTextureView.new())
	var done := rd.storage_buffer_create(4)
	if not owned.is_valid() or not done.is_valid():
		if owned.is_valid():
			rd.free_rid(owned)
		if done.is_valid():
			rd.free_rid(done)
		receiver.release_frame(frame.sequence)
		return RID()
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output.binding = 0
	output.add_id(owned)
	var completion := RDUniform.new()
	completion.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	completion.binding = 1
	completion.add_id(done)
	var uniforms := rd.uniform_set_create([output, completion], _conversion_shader, 0)
	if not uniforms.is_valid():
		rd.free_rid(owned)
		rd.free_rid(done)
		receiver.release_frame(frame.sequence)
		return RID()
	var params := PackedByteArray()
	params.resize(16)
	params.encode_u64(0, frame.address)
	params.encode_u32(8, frame.width)
	params.encode_u32(12, int(frame.bgra))
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, _conversion_pipeline)
	rd.compute_list_bind_uniform_set(commands, uniforms, 0)
	rd.compute_list_set_push_constant(commands, params, params.size())
	rd.compute_list_dispatch(commands, ceili(frame.width / 8.0), ceili(frame.height / 8.0), 1)
	rd.compute_list_end()
	rd.free_rid(uniforms)
	# The readback depends on the entire dispatch, not just invocation zero.
	# Capturing receiver keeps imported memory alive across close/deselection.
	_linux_completions[frame.sequence] = done
	var callback := _linux_copy_done.bind(receiver, frame.sequence, done, self)
	if rd.buffer_get_data_async(done, callback, 0, 4) != OK:
		# Allocation failure: flush the dispatch before releasing its source.
		_linux_copy_done(rd.buffer_get_data(done, 0, 4), receiver, frame.sequence, done, self)
	return owned


func _convert_windows_frame(rd: RenderingDevice, source: RID, frame: Dictionary) -> RID:
	if not _conversion_shader.is_valid():
		var code := RDShaderSource.new()
		code.source_compute = CONVERSION_SHADER
		_conversion_shader = rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(code))
		if not _conversion_shader.is_valid():
			return RID()
		_conversion_pipeline = rd.compute_pipeline_create(_conversion_shader)
		_conversion_sampler = rd.sampler_create(RDSamplerState.new())
	if not _conversion_pipeline.is_valid() or not _conversion_sampler.is_valid():
		return RID()
	var description := RDTextureFormat.new()
	# Copy BGRA into an RGBA texture through a shader. Sampling converts
	# the channel order. Godot 4.7.2's 3D path needs an RGBA sRGB view,
	# which it cannot create directly from the BGRA D3D12 resource.
	description.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	description.width = frame.width
	description.height = frame.height
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	description.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	description.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	var owned := rd.texture_create(description, RDTextureView.new())
	if not owned.is_valid():
		return RID()
	if not receiver.bind_lifetime(
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_TEXTURE, owned, 0)
	):
		rd.free_rid(owned)
		return RID()
	var input := RDUniform.new()
	input.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	input.binding = 0
	input.add_id(_conversion_sampler)
	input.add_id(source)
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output.binding = 1
	output.add_id(owned)
	var uniforms := rd.uniform_set_create([input, output], _conversion_shader, 0)
	if not uniforms.is_valid():
		rd.free_rid(owned)
		return RID()
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, _conversion_pipeline)
	rd.compute_list_bind_uniform_set(commands, uniforms, 0)
	rd.compute_list_dispatch(commands, ceili(frame.width / 8.0), ceili(frame.height / 8.0), 1)
	rd.compute_list_end()
	rd.free_rid(uniforms)
	return owned


func start_shared(server_pid: int) -> bool:
	if (
		OS.get_name() not in ["macOS", "Windows"] or server_pid <= 0
		or RenderingServer.get_current_rendering_driver_name() != ("d3d12" if OS.get_name() == "Windows" else "metal")
		or RenderingServer.get_rendering_device() == null
		or not ClassDB.class_exists("ChromiumGpuReceiver")
	):
		return false
	receiver = ClassDB.instantiate("ChromiumGpuReceiver")
	if not receiver.has_method("start_shared"):
		return false
	endpoint = receiver.start_shared(server_pid)
	return not endpoint.is_empty()


func proof_ready() -> bool:
	_mutex.lock()
	var value := _proof_ready
	_mutex.unlock()
	return value


func last_error() -> String:
	_mutex.lock()
	var value := _error
	_mutex.unlock()
	return value


func frames() -> int:
	_mutex.lock()
	var value := _frames
	_mutex.unlock()
	return value


func tick() -> void:
	_mutex.lock()
	var schedule := not _pending and not _closed
	if schedule:
		_pending = true
	_mutex.unlock()
	if schedule:
		# Binding a RefCounted keeper makes close-during-import safe.
		RenderingServer.call_on_render_thread(_receive.bind(self))


func _receive(_keeper: RefCounted) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_mutex.lock()
		_error = "No rendering device is available"
		_pending = false
		_mutex.unlock()
		return
	if OS.get_name() == "Linux":
		_receive_linux(rd)
		_mutex.lock()
		_pending = false
		_mutex.unlock()
		return
	var frame: Dictionary = receiver.receive(
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0)
	)
	if frame.has("error") or frame.has("probe"):
		_mutex.lock()
		if frame.has("error"):
			_error = str(frame.error)
		else:
			_proof_ready = true
		_mutex.unlock()
	elif frame.has("handle"):
		var format := RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM if frame.bgra else RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		if OS.get_name() == "Windows":
			usage |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var next := rd.texture_create_from_extension(
			RenderingDevice.TEXTURE_TYPE_2D,
			format,
			RenderingDevice.TEXTURE_SAMPLES_1,
			usage,
			frame.handle,
			frame.width,
			frame.height,
			1,
			1,
		)
		if next.is_valid() and OS.get_name() == "Windows":
			# Copy into a Godot-owned texture. The external D3D12 wrapper only
			# borrows the imported resource.
			#
			# Keep the source's COM reference alive with the copy until deferred
			# GPU work finishes.
			var owned := _convert_windows_frame(rd, next, frame)
			rd.free_rid(next)
			next = owned
		if next.is_valid():
			_publish_or_hold(rd, next, Vector2i(frame.width, frame.height))
		else:
			_mutex.lock()
			_error = "Godot could not import the shared chromium texture"
			_mutex.unlock()
	_mutex.lock()
	_pending = false
	_mutex.unlock()


func _receive_linux(rd: RenderingDevice) -> void:
	if not rd.has_feature(RenderingDevice.SUPPORTS_BUFFER_DEVICE_ADDRESS):
		return
	var frame: Dictionary = receiver.receive_linux(
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_PHYSICAL_DEVICE, RID(), 0),
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0),
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_COMMAND_QUEUE, RID(), 0),
		rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_QUEUE_FAMILY, RID(), 0),
	)
	if frame.is_empty():
		return
	var next := _convert_linux_frame(rd, frame)
	if next.is_valid():
		_publish_or_hold(rd, next, Vector2i(frame.width, frame.height))


func _publish_or_hold(rd: RenderingDevice, next: RID, size: Vector2i) -> void:
	if _unpublished.is_valid():
		# A newer frame supersedes one that never reached the screen.
		rd.free_rid(_unpublished)
		_unpublished = RID()
	_mutex.lock()
	var hold := defer_publish and _rid.is_valid() and Vector2i(texture.get_size()) == size
	_holding = hold
	_mutex.unlock()
	if hold:
		_unpublished = next
		return
	texture.texture_rd_rid = next
	if _rid.is_valid():
		rd.free_rid(_rid)
	_rid = next
	_mutex.lock()
	_frames += 1
	_mutex.unlock()


func holding() -> bool:
	_mutex.lock()
	var value := _holding
	_mutex.unlock()
	return value


## Shows the held frame. Same size, so the texture's pixels are swapped
## without Texture2DRD's `changed` signal: it made every TextureRect showing
## the page record its drawing again, which redrew the workspace canvas.
func publish() -> void:
	RenderingServer.call_on_render_thread(_publish.bind(self))


func _publish(_keeper: RefCounted) -> void:
	if not _unpublished.is_valid(): return
	RenderingServer.texture_replace(texture.get_rid(), RenderingServer.texture_rd_create(_unpublished))
	RenderingServer.get_rendering_device().free_rid(_rid)
	_rid = _unpublished
	_unpublished = RID()
	_mutex.lock()
	_holding = false
	_frames += 1
	_mutex.unlock()


func close() -> void:
	_mutex.lock()
	_closed = true
	_mutex.unlock()
	RenderingServer.call_on_render_thread(_release.bind(self))


func _release(_keeper: RefCounted) -> void:
	var rd := RenderingServer.get_rendering_device()
	# Closing may stop rendering altogether. Flush only the four-byte completion
	# records so imported allocations never depend on an arbitrary frame delay.
	for sequence in _linux_completions.keys():
		if _linux_completions.has(sequence):
			var done: RID = _linux_completions[sequence]
			rd.buffer_get_data(done, 0, 4)
			_linux_release_frame(receiver, sequence, done, self)
	texture.texture_rd_rid = RID()
	if _rid.is_valid():
		RenderingServer.get_rendering_device().free_rid(_rid)
		_rid = RID()
	if _unpublished.is_valid():
		rd.free_rid(_unpublished)
		_unpublished = RID()
	if _conversion_pipeline.is_valid():
		rd.free_rid(_conversion_pipeline)
	if _conversion_shader.is_valid():
		rd.free_rid(_conversion_shader)
	if _conversion_sampler.is_valid():
		rd.free_rid(_conversion_sampler)
	receiver = null
