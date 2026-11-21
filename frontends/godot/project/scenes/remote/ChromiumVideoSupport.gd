extends RefCounted
## Hardware codecs only. Android names come from MediaCodecInfo, then the NDK
## creates that exact implementation rather than silently choosing software.
static var _probed := false
static var _codecs := PackedStringArray()
static var _implementations: Dictionary[String, String] = { }


static func codecs() -> PackedStringArray:
	if _probed:
		return _codecs
	_probed = true
	if not ClassDB.class_exists("ChromiumVideoDecoder"):
		return _codecs
	if not OS.has_feature("android"):
		var native: RefCounted = ClassDB.instantiate("ChromiumVideoDecoder")
		_codecs = native.supported_codecs()
		return _codecs
	var bridge: Object = Engine.get_singleton("JavaClassWrapper")
	if bridge == null:
		return _codecs
	var sdk: Variant = bridge.wrap("android.os.Build$VERSION")
	if sdk == null or int(sdk.SDK_INT) < 29:
		return _codecs
	var registry: Variant = bridge.wrap("android.media.MediaCodecList")
	if registry == null:
		return _codecs
	var types: Dictionary[String, String] = { "video/av01": "av1", "video/hevc": "hevc", "video/avc": "h264" }
	for index in int(registry.getCodecCount()):
		var info: Variant = registry.getCodecInfoAt(index)
		if info == null or info.isEncoder() or not info.isHardwareAccelerated():
			continue
		for mime in info.getSupportedTypes():
			if types.has(str(mime)):
				var capabilities: Variant = info.getCapabilitiesForType(str(mime))
				if capabilities.isFeatureRequired("secure-playback") or capabilities.isFeatureRequired("tunneled-playback"):
					continue
				var codec: String = types[str(mime)]
				if not _implementations.has(codec):
					_implementations[codec] = str(info.getName())
	if bridge.get_exception() != null:
		_implementations.clear()
	for codec in ["av1", "hevc", "h264"]:
		if _implementations.has(codec):
			_codecs.append(codec)
	return _codecs


static func start(decoder: RefCounted, codec: String, width: int, height: int, nv12: bool) -> bool:
	codecs()
	return decoder.start(codec, width, height, str(_implementations.get(codec, "")), nv12)
