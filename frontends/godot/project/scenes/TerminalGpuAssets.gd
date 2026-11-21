extends RefCounted
## Reliable immutable assets over the existing authenticated IOSurface channel.
## Unlike video, every sequence is retained until matched with its descriptor.
var receiver: RefCounted
var endpoint := ""
var _mutex := Mutex.new()
var _pending := false
var _closed := false
var _proof := false
var _error := ""
var _frames: Dictionary = {}
var _descriptors: Dictionary = {}

func start(server_pid: int) -> bool:
	if OS.get_name() != "macOS" or server_pid <= 0 or RenderingServer.get_current_rendering_driver_name() != "metal" or RenderingServer.get_rendering_device() == null:
		return false
	receiver = ClassDB.instantiate("ChromiumGpuReceiver")
	endpoint = receiver.start_shared(server_pid)
	return not endpoint.is_empty()

func describe(header: Dictionary) -> void:
	_descriptors[int(header.sequence)] = header

func pending_descriptors() -> Array:
	return _descriptors.values()

func proof_ready() -> bool:
	_mutex.lock()
	var result := _proof
	_mutex.unlock()
	return result

func last_error() -> String:
	_mutex.lock()
	var result := _error
	_mutex.unlock()
	return result

func poll() -> Array[Dictionary]:
	var ready: Array[Dictionary] = []
	_mutex.lock()
	for sequence in _descriptors.keys():
		if _frames.has(sequence):
			var descriptor: Dictionary = _descriptors[sequence]
			var frame: Dictionary = _frames[sequence]
			if int(descriptor.width) == int(frame.width) and int(descriptor.height) == int(frame.height):
				descriptor.asset_texture = frame.texture
				ready.append(descriptor)
			else:
				_error = "Shared image dimensions did not match its descriptor"
			_frames.erase(sequence)
			_descriptors.erase(sequence)
	var schedule := not _closed and not _pending and _frames.size() < 32
	if schedule:
		_pending = true
	_mutex.unlock()
	if schedule:
		RenderingServer.call_on_render_thread(_receive.bind(self))
	return ready

func _receive(_keeper: RefCounted) -> void:
	var rd := RenderingServer.get_rendering_device()
	var frame: Dictionary = receiver.receive(rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0))
	if frame.has("handle"):
		var owned := rd.texture_create_from_extension(RenderingDevice.TEXTURE_TYPE_2D, RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM, RenderingDevice.TEXTURE_SAMPLES_1, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT, frame.handle, frame.width, frame.height, 1, 1)
		if owned.is_valid():
			var texture := preload("res://scenes/TerminalAssetTexture.gd").new()
			texture.texture_rd_rid = owned
			_mutex.lock()
			_frames[int(frame.sequence)] = {"texture": texture, "width": frame.width, "height": frame.height}
			_mutex.unlock()
		else:
			frame.error = "Shared terminal texture import failed"
	_mutex.lock()
	if frame.has("probe"):
		_proof = true
	if frame.has("error"):
		_error = str(frame.error)
	_pending = false
	_mutex.unlock()

func close() -> void:
	_mutex.lock()
	_closed = true
	_frames.clear()
	_mutex.unlock()
	_descriptors.clear()
