extends SceneTree
## Run in a small project containing ChromiumGpuStream and the Linux extension.
const Stream := preload("res://scenes/ChromiumGpuStream.gd")
var stream: RefCounted
var started := Time.get_ticks_msec()
var checked := 0
var checking := false
var producer := -1
var ending := false
var state := Mutex.new()


func _initialize() -> void:
	stream = Stream.new()
	if not stream.start():
		push_error("Linux Vulkan receiver did not start")
		quit(1)
		return
	producer = OS.create_process(
		OS.get_environment("GRAFFITTY_GPU_TEST_PRODUCER"),
		[stream.endpoint],
	)
	if producer <= 0:
		quit(1)


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - started > 30000:
		push_error("Timed out waiting for GPU frames")
		quit(1)
		return false
	if stream == null:
		return false
	stream.tick()
	var count: int = stream.frames()
	state.lock()
	var schedule := count > checked and not checking and not ending
	if schedule:
		checking = true
	state.unlock()
	if schedule:
		RenderingServer.call_on_render_thread(_check_pixels.bind(stream))
	return false


func _check_pixels(keeper: RefCounted) -> void:
	var rd := RenderingServer.get_rendering_device()
	var texture: RID = keeper.texture.texture_rd_rid
	if not texture.is_valid():
		state.lock()
		checking = false
		state.unlock()
		return
	# Diagnostic pixel readback exists only in this test.
	var pixels := rd.texture_get_data(texture, 0)
	if pixels.is_empty():
		push_error("GPU diagnostic readback returned no pixels")
		call_deferred("quit", 1)
		return
	for i in range(0, pixels.size(), 4):
		if (
			pixels[i] != 0x33 or pixels[i + 1] != 0x66
			or pixels[i + 2] != 0xcc or pixels[i + 3] != 0xff
		):
			push_error("GPU channel/stride mismatch at byte %d: %s" % [i, pixels.slice(i, i + 4)])
			call_deferred("quit", 1)
			return
	var count: int = keeper.frames()
	state.lock()
	checked = count
	checking = false
	if count >= 24:
		ending = true
	state.unlock()
	if count >= 24:
		call_deferred("_finish")


func _finish() -> void:
	stream.close()
	stream = null
	if producer > 0 and OS.is_process_running(producer):
		OS.kill(producer)
	# Allow async completion callbacks to retire in-flight imports after close.
	for i in range(10):
		await process_frame
	print(
		"PASS: Vulkan process sharing -> Godot compute -> RGBA texture; BGRA/RGBA, resize, close with frames in flight"
	)
	quit(0)
