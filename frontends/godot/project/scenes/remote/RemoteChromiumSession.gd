extends "res://scenes/ChromiumSession.gd"
const VideoFrame = preload("res://scenes/remote/ChromiumVideoFrame.gd")
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")

## Decoded CPU frame, also available before presentation in headless clients.
## Video converted on the GPU (NV12) has no CPU image and does not emit it.
signal frame_decoded(image: Image)
## Same chromium chrome and workspace pane; Chromium/profile live on the server.
var connection: Node
var pending_commands := 0
var _clipboard_busy := false
var _clipboard_requests: Array[int] = []
var _clipboard_error := ""
## Force the viewer clipboard bridge even when Chromium runs on this computer.
## The clipboard E2E uses it to cover the remote path against a local server.
var clipboard_bridge := false
var pending_frame := PackedByteArray()
var video_decoder: RefCounted
var video_codec := ""
var video_epoch := -1
var video_source_size := Vector2.ZERO
var video_sequence := 0
## Encoded video bytes received, for measuring the stream's delivered bitrate.
var video_bytes := 0
## Stream recoveries: keyframe requests, and decoders discarded mid-stream.
var video_resets := 0
var video_decoder_drops := 0
var video_waiting_key := true
var frame_format := "png"
var video_error := ""
## Flow numbers submitted to the current decoder and acknowledged to the owner.
var _video_submitted := 0
## Arrival time (ticks msec) of each submitted, unacknowledged flow number.
var _video_arrivals: Dictionary[int, int] = {}
var _video_acknowledged := 0
var gpu: RefCounted
var gpu_peer: RefCounted
var gpu_active := false
var gpu_error := ""
var gpu_frames := 0
var gpu_generation := 0
## In-app notices; the application's service unless one is supplied.
var notifications: Node
var _nv12_view: SubViewport
var _nv12_planes: Array[ImageTexture] = []
## A decoded frame that keeps `texture`, waiting for frame_pre_draw.
var _held_frame: Dictionary = { }




func apply_state(value: Dictionary) -> void:
	main_window = bool(value.get("mainWindow", true))
	var previous_failure := failure_reason
	failure_reason = str(value.get("error", ""))
	restartable = bool(value.get("restartable", false))
	if failure_reason.is_empty(): restarting = false
	if not failure_reason.is_empty():
		_reset_gpu()
		gpu_peer = null
		texture = null
		_release_nv12()
		_queue.clear()
		# A relaunched browser starts at its default viewport.
		_preview_size = Vector2i.ZERO
		if previous_failure.is_empty() and bool(value.get("crashed", false)):
			_announce_failure()
	if value.get("contextMenu") is Dictionary:
		accept_context_menu(value.contextMenu)
	var was_crashed := page_crashed
	_accept({ "action": "chrome-state" }, value)
	if page_crashed and not was_crashed and failure_reason.is_empty():
		_announce_page_crash()
	# The relaunched browser may already be ready, which is not a transition.
	if not previous_failure.is_empty() and failure_reason.is_empty() and _preview_request != Vector2.ZERO:
		set_preview_size(_preview_request)
	pid = int(value.get("pid", -1))
	profile_directory = str(value.get("profile", ""))
	persistent_profile = not bool(value.get("temporaryProfile", true))
	primary_target_id = str(value.get("primaryTargetId", ""))
	directory = str(value.get("runtimeDirectory", ""))
	_refresh_status()


func _refresh_status() -> void:
	if not failure_reason.is_empty() or not video_error.is_empty():
		status = failure_reason if not failure_reason.is_empty() else video_error
	elif not _clipboard_error.is_empty():
		status = _clipboard_error
	elif gpu_active and gpu_frames > 0:
		status = "Local Chromium · shared GPU texture"
	elif video_codec.is_empty() and frame_format == "png" and (not pending_frame.is_empty() or texture is ImageTexture):
		_set_portable_status("png")
	else:
		_set_portable_status(video_codec)
	changed.emit()


func _set_portable_status(codec: String) -> void:
	var transport := _gpu_transport()
	var local_endpoint: bool = transport != null and "url" in transport and (
		transport.url == "shared://local" or transport.url.begins_with("ipc://"))
	if codec.is_empty():
		status = "Chromium" if local_endpoint else "Remote Chromium"
	elif codec == "png":
		set_status("Chromium · %s preview" if local_endpoint else "Remote Chromium · %s preview", [codec.to_upper()])
	else:
		set_status("Chromium · %s" if local_endpoint else "Remote Chromium · %s", [codec.to_upper()])


func apply_frame(bytes: PackedByteArray) -> void:
	if not failure_reason.is_empty(): return
	# Network delivery may outpace rendering. Decode only the newest frame.
	pending_frame = bytes


func apply_video_frame(header: Dictionary, bytes: PackedByteArray) -> void:
	if not failure_reason.is_empty(): return
	if gpu_active:
		return # Old queued video must not replace an imported native texture.
	video_bytes += bytes.size()
	var frame := VideoFrame.parse(header)
	if not frame.invalid_reason.is_empty():
		video_error = "Invalid chromium video frame: " + frame.invalid_reason
		status = video_error
		_drop_video_decoder()
		video_waiting_key = true
		changed.emit()
		return
	# A submitted frame is acknowledged once the codec accepts it, so a slow
	# device's frame window throttles the stream instead of overflowing the
	# decoder and forcing keyframe restarts. Others are acknowledged on receipt.
	if _apply_video_frame(frame, bytes, int(header.get("arrived_msec", Time.get_ticks_msec()))):
		header["ack_deferred"] = true


func _apply_video_frame(frame: VideoFrame.Header, bytes: PackedByteArray, arrived_msec: int) -> bool:
	var codec := frame.format
	if codec == "error":
		video_error = frame.error
		status = video_error
		changed.emit()
		return false
	if codec == "png":
		video_source_size = Vector2.ZERO
		frame_format = codec
		video_codec = ""
		video_error = ""
		_drop_video_decoder()
		video_waiting_key = true
		_set_portable_status(codec)
		apply_frame(bytes)
		return false
	if codec not in ["av1", "hevc", "h264"]:
		return false
	video_source_size = Vector2(frame.source_size)
	var epoch := frame.epoch
	var sequence := frame.sequence
	var key := frame.key
	if codec != video_codec or epoch != video_epoch or sequence != video_sequence + 1:
		video_waiting_key = true
	if video_waiting_key:
		# Between attempts to start a decoder, frames are neither decodable
		# nor a reason to ask for another keyframe.
		if Time.get_ticks_msec() < _video_retry_at:
			return false
		if not key:
			video_resets += 1
			connection.reset_chromium_video(session_id)
			return false
		# A dropped packet needs a fresh keyframe, not a new MediaCodec instance.
		# Reuse the decoder for the same encoder epoch; codec/size changes still
		# start a fresh decoder. Repeated recreation can stall Android input.
		if video_decoder == null or codec != video_codec or epoch != video_epoch:
			_drop_video_decoder()
			video_decoder = _new_video_decoder()
			video_codec = codec
			video_epoch = epoch
			if not preload("res://scenes/remote/ChromiumVideoSupport.gd").start(video_decoder, codec, frame.size.x, frame.size.y, _converts_on_gpu()):
				_video_start_failed()
				return false
			_video_start_failures = 0
		video_waiting_key = false
		video_error = ""
		_set_portable_status(codec)
	video_sequence = sequence
	if not video_decoder.submit(bytes, frame.flow):
		video_waiting_key = true
		_drop_video_decoder()
		video_resets += 1
		connection.reset_chromium_video(session_id)
		return false
	_video_submitted = maxi(_video_submitted, frame.flow)
	_video_arrivals[frame.flow] = arrived_msec
	return true


const VIDEO_START_ATTEMPTS := 3
const VIDEO_START_RETRY_MSEC := 250
var _video_start_failures := 0
var _video_retry_at := 0


func _new_video_decoder() -> RefCounted:
	return ClassDB.instantiate("ChromiumVideoDecoder")


## A suspended app can return with an invalidated hardware decode session, and
## resubscribing always restarts the stream at a keyframe. Discard the decoder
## so that keyframe builds a new one.
##
## This is not a codec failure: the codec stays negotiated and the last
## presented texture stays visible.
func release_video_decoder() -> void:
	if video_decoder == null: return
	_drop_video_decoder()
	video_waiting_key = true


## Frames queued to a discarded decoder will never be consumed. Acknowledge
## them now: an unacknowledged frame window would stop this stream for good.
func _drop_video_decoder() -> void:
	if video_decoder != null: video_decoder_drops += 1
	video_decoder = null
	_acknowledge_video(_video_submitted)


func _acknowledge_video(frame: int) -> void:
	if frame <= _video_acknowledged: return
	_video_acknowledged = frame
	var held := Time.get_ticks_msec() - int(_video_arrivals.get(frame, Time.get_ticks_msec()))
	for flow in _video_arrivals.keys():
		if flow <= frame: _video_arrivals.erase(flow)
	if is_instance_valid(connection) and connection.connected:
		connection.acknowledge_chromium(session_id, frame, held)


func _notifications() -> Node:
	if notifications != null or not is_inside_tree(): return notifications
	var application := get_node_or_null("/root/TerminalApplication")
	return application.notifications if application != null else null


## Every unexpected stop is announced once; the pane also offers a restart.
func _announce_failure() -> void:
	var notices := _notifications()
	if notices == null: return
	var name := title if not title.is_empty() else tr("Chromium")
	var body := "%s stopped unexpectedly: %s"
	notices.post(tr("Chromium stopped"), tr(body) % [name, failure_reason], self, "error", 20.0,
		"chromium-stopped-%d-%d" % [session_id, Time.get_ticks_usec()],
		{"title": "Chromium stopped", "body": body, "args": [name, failure_reason]})


## A page whose renderer died keeps its last frame; say so once.
func _announce_page_crash() -> void:
	var notices := _notifications()
	if notices == null: return
	var name := title if not title.is_empty() else tr("Chromium")
	var body := "%s crashed. Reload the page to continue."
	notices.post(tr("Page crashed"), tr(body) % name, self, "error", 12.0,
		"chromium-page-crashed-%d-%d" % [session_id, Time.get_ticks_usec()],
		{"title": "Page crashed", "body": body, "args": [name]})


## Relaunch this stopped chromium in the same pane with its last pages.
func restart() -> Dictionary:
	restarting = true
	status = "Restarting Chromium…"
	changed.emit()
	var reply: Dictionary = await connection.remote_call(tab_id, "chromium.restart", {"chromium": "%%%d" % session_id})
	# Another viewer relaunched it first: the browser is recovering.
	if reply.has("error") and str(reply.error.get("code", "")) == "chromium_running":
		restarting = false
		changed.emit()
		return {"result": {"restarted": "%%%d" % session_id}}
	if reply.has("error"):
		restarting = false
		var message := str(reply.error.get("message", "Chromium restart failed"))
		status = message
		var notices := _notifications()
		if notices != null:
			notices.post(tr("Chromium restart failed"), message, self, "error", 12.0, "", {"title": "Chromium restart failed"})
		changed.emit()
	return reply


## A device can refuse one more hardware decoder for a moment, while another
## stream's decoder is starting or being released. Try again a few times,
## spaced out, before telling the server this pane cannot decode the codec;
## the server then offers this pane the next codec and leaves other panes alone.
func _video_start_failed() -> void:
	_video_start_failures += 1
	if _video_start_failures >= VIDEO_START_ATTEMPTS:
		_reject_video("Hardware decoder initialization failed")
		return
	print("[chromium video] ", video_codec, " decoder did not start; retrying (", _video_start_failures, ")")
	_drop_video_decoder()
	video_waiting_key = true
	_video_retry_at = Time.get_ticks_msec() + VIDEO_START_RETRY_MSEC * _video_start_failures


func _reject_video(reason: String) -> void:
	_video_start_failures = 0
	_video_retry_at = 0
	print("[chromium video] Rejecting ", video_codec, ": ", reason)
	set_status("Hardware %s decoder failed; negotiating fallback…", [video_codec])
	connection.reject_chromium_codec(session_id, video_codec)
	_drop_video_decoder()
	video_waiting_key = true
	changed.emit()


func _update_frame() -> void:
	if not failure_reason.is_empty(): return
	var previous_texture := texture
	var previous_format := frame_format
	if gpu != null:
		gpu.defer_publish = present_at_draw
		gpu.tick()
		if not gpu.last_error().is_empty():
			reject_gpu(gpu.last_error())
		elif gpu_active:
			if gpu.holding(): RenderUpdates.before_draw(_present_gpu)
			var imported: int = gpu.frames()
			if imported > gpu_frames:
				frames += imported - gpu_frames
				gpu_frames = imported
				texture = gpu.texture
				status = "Local Chromium · shared GPU texture"
				if texture != previous_texture: changed.emit()
			return
	var image: Image
	if video_decoder != null:
		_acknowledge_video(video_decoder.consumed())
		var frame: Dictionary = video_decoder.take_frame()
		if frame.has("error"):
			_reject_video(str(frame.error))
			return
		if frame.has("y"):
			frame_format = video_codec
			frame.size = Vector2i(int(frame.width), int(frame.height))
			if _nv12_view != null and _nv12_view.size == frame.size and _hold(frame, previous_format): return
			_present_nv12(frame.size, frame.y, frame.uv)
			frames += 1
			presented.emit()
			if texture != previous_texture or frame_format != previous_format: changed.emit()
			return
		if not frame.has("rgba"):
			return
		frame_format = video_codec
		image = Image.create_from_data(int(frame.width), int(frame.height), false, Image.FORMAT_RGBA8, frame.rgba)
	else:
		if pending_frame.is_empty():
			return
		image = Image.new()
		var bytes := pending_frame
		pending_frame = PackedByteArray()
		var result := image.load_png_from_buffer(bytes)
		if result != OK:
			return
	_release_nv12()
	# Keep texture format stable when negotiation falls back from video to PNG.
	image.convert(Image.FORMAT_RGBA8)
	var same_size := texture is ImageTexture and texture.get_size() == Vector2(image.get_size())
	if same_size and _hold({ "image": image, "size": image.get_size() }, previous_format): return
	if same_size:
		_update_pixels(texture, image)
	else:
		texture = ImageTexture.create_from_image(image)
	frames += 1
	frame_decoded.emit(image)
	presented.emit()
	# Updating the existing texture already redraws its consumers. Rebuilding
	# the entire workspace UI for every video frame stalls mobile presentation.
	if texture != previous_texture or frame_format != previous_format:
		changed.emit()


## Defers a frame that keeps `texture` to frame_pre_draw for a page the world
## draws beneath the canvas; see ChromiumSession.present_at_draw.
func _hold(frame: Dictionary, previous_format: String) -> bool:
	_held_frame = { }
	if not present_at_draw or frame_format != previous_format: return false
	_held_frame = frame
	RenderUpdates.before_draw(_present_held)
	return true


func _present_gpu() -> void:
	if gpu == null: return
	gpu.publish()
	presented.emit()


func _present_held() -> void:
	var frame := _held_frame
	_held_frame = { }
	if frame.is_empty() or not failure_reason.is_empty(): return
	if frame.has("image"):
		# A newer frame of another size or kind may have replaced the texture.
		if not texture is ImageTexture or Vector2i(texture.get_size()) != frame.size: return
		_update_pixels(texture, frame.image)
		frames += 1
		frame_decoded.emit(frame.image)
	else:
		if _nv12_view == null or _nv12_view.size != frame.size: return
		_present_nv12(frame.size, frame.y, frame.uv)
		frames += 1
	presented.emit()


## A tablet's main thread spent about 11 ms uploading each 848×2160 frame as
## 7.3 MB of CPU-converted RGBA, and the decoder's conversions evicted its
## caches.
##
## Its NV12 planes are 2.7 MB (about 4 ms) and convert on the GPU. Headless
## and desktop clients keep RGBA frames.
func _converts_on_gpu() -> bool:
	return OS.has_feature("mobile")


## The page texture stays one stable object; each frame refreshes its planes
## and renders the conversion once.
func _present_nv12(size: Vector2i, luma: PackedByteArray, chroma: PackedByteArray) -> void:
	var planes: Array[Image] = [Image.create_from_data(size.x, size.y, false, Image.FORMAT_R8, luma),
		Image.create_from_data((size.x + 1) >> 1, (size.y + 1) >> 1, false, Image.FORMAT_RG8, chroma)]
	if _nv12_view == null or _nv12_view.size != size:
		_release_nv12()
		_nv12_planes = [ImageTexture.create_from_image(planes[0]), ImageTexture.create_from_image(planes[1])]
		var material := ShaderMaterial.new()
		material.shader = preload("res://scenes/chromium_nv12.gdshader")
		material.set_shader_parameter("luma", _nv12_planes[0])
		material.set_shader_parameter("chroma", _nv12_planes[1])
		var page := ColorRect.new()
		page.material = material
		page.size = Vector2(size)
		_nv12_view = SubViewport.new()
		_nv12_view.size = size
		_nv12_view.disable_3d = true
		_nv12_view.transparent_bg = false
		_nv12_view.add_child(page)
		add_child(_nv12_view)
	else:
		_update_pixels(_nv12_planes[0], planes[0])
		_update_pixels(_nv12_planes[1], planes[1])
	_nv12_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	texture = _nv12_view.get_texture()


## Same-size pixels only. ImageTexture.update() also emits `changed`, and
## every TextureRect showing the page then re-records its drawing: one more
## frame, and a workspace canvas redraw, for each page frame.
static func _update_pixels(target: ImageTexture, image: Image) -> void:
	RenderingServer.texture_2d_update(target.get_rid(), image, 0)


func _release_nv12() -> void:
	if _nv12_view == null: return
	_nv12_view.queue_free()
	_nv12_view = null
	_nv12_planes.clear()


func request(action: String, args: Dictionary = { }, timeout_ms := 20000) -> Dictionary:
	var started: Dictionary = await connection.remote_call(
		tab_id,
		"chromium.command",
		{ "chromium": "%%%d" % session_id, "action": action, "args": args },
	)
	if started.has("error"):
		return started
	var deadline := Time.get_ticks_msec() + timeout_ms
	while connection.connected and Time.get_ticks_msec() < deadline:
		var result: Dictionary = await connection.remote_call(
			tab_id,
			"chromium.result",
			{ "chromium": "%%%d" % session_id, "ticket": int(started.result.ticket) },
		)
		if result.has("error"):
			return result
		if result.get("result") is Dictionary:
			return result.result
		await get_tree().create_timer(.025).timeout
	return { "error": { "code": "chromium_timeout", "message": "Remote chromium request timed out" } }


func command(action: String, args: Dictionary = { }) -> int:
	if (
		action == "cdp" and args.get("method") == "Input.dispatchMouseEvent"
		and args.get("params", { }).get("type") == "mouseMoved"
	):
		for index in range(_queue.size() - 1, -1, -1):
			var queued: Dictionary = _queue[index]
			if (
				queued.get("method") == "Input.dispatchMouseEvent"
				and queued.get("params", { }).get("type") == "mouseMoved"
			):
				_queue.remove_at(index)
	return super.command(action, args)


func _gpu_transport() -> Node:
	if not is_instance_valid(connection): return null
	return connection.owners.get(session_id) if "owners" in connection else connection


func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("RemoteChromiumSession", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	if not failure_reason.is_empty(): return
	var transport := _gpu_transport()
	if transport == null or not transport.connected:
		if gpu_peer != null:
			_reset_gpu()
			gpu_peer = null
		return
	if gpu_peer != transport.socket:
		# Flow numbers restart with each connection.
		_video_submitted = 0
		_video_acknowledged = 0
		_reset_gpu()
		gpu_peer = transport.socket
		_begin_gpu(gpu_generation, gpu_peer, transport)
	_update_frame()
	_flush_motion()
	while not _queue.is_empty() and pending_commands < 8:
		_dispatch_command(_queue.pop_front())


func _dispatch_command(item: Dictionary) -> void:
	pending_commands += 1
	var response := await request(str(item.action), item)
	if response.has("error"):
		status = str(response.error.get("message", "Remote chromium failed"))
	pending_commands -= 1


func _send_input(method: String, params: Dictionary) -> void:
	var response: Dictionary = await connection.remote_call(tab_id, "chromium.input", {
		"chromium": "%%%d" % session_id,
		"event": { "method": method, "params": params },
	})
	if response.has("error"):
		status = str(response.error.get("message", "Chromium input failed"))


func remote_input(event: InputEvent, extent: Vector2) -> void:
	# Clipboard shortcuts belong to the viewer's OS, not the server's desktop.
	# A server on this computer shares that OS clipboard, so Chromium's native
	# copy/cut/paste handles iframes, editors, rich data and page handlers.
	if event is InputEventKey and chromium_ready and texture != null and not native_clipboard():
		var shortcut: bool = event.meta_pressed if OS.get_name() == "macOS" else event.ctrl_pressed
		if shortcut and not event.alt_pressed and not event.shift_pressed and event.keycode in [KEY_C, KEY_X, KEY_V]:
			if event.pressed and not event.echo: _clipboard_shortcut(event.keycode)
			return
	super.remote_input(event, extent)


func native_clipboard() -> bool:
	var transport := _gpu_transport()
	return not clipboard_bridge and transport != null and (
		transport.url == "shared://local" or transport.url.begins_with("ipc://")
	)


func _clipboard_shortcut(code: int) -> void:
	if _clipboard_requests.size() >= 16:
		status = "Browser clipboard queue is full"
		return
	if not _clipboard_error.is_empty():
		_clipboard_error = ""
		_refresh_status()
	_clipboard_requests.append(code)
	if _clipboard_busy: return
	_clipboard_busy = true
	while not _clipboard_requests.is_empty():
		await _clipboard_operation(_clipboard_requests.pop_front())
	_clipboard_busy = false


func _clipboard_failed(message: String) -> void:
	# Routine chrome-state updates must not erase an input error before the
	# viewer can read it. The next clipboard shortcut clears this error.
	_clipboard_error = message
	status = message
	changed.emit()


func _clipboard_operation(code: int) -> void:
	if code == KEY_V:
		var text := DisplayServer.clipboard_get()
		if JSON.stringify({"method": "Input.insertText", "params": {"text": text}}).to_utf8_buffer().size() > 64 * 1024:
			_clipboard_failed("Clipboard text exceeds the browser input limit")
			return
		var pasted := await request("cdp", {"method": "Input.insertText", "params": {"text": text}})
		if pasted.has("error"):
			_clipboard_failed(str(pasted.error.get("message", "Chromium paste failed")))
		return
	# Extract and (for Cut) delete one selection in the same renderer task.
	# Passwords are never copied. This bridge transfers plain text only.
	var expression := """(() => {
	let el = document.activeElement;
	while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
	if (el?.type === 'password') return null;
	const field = el && typeof el.selectionStart === 'number';
	const text = field ? el.value.slice(el.selectionStart, el.selectionEnd) : String(document.getSelection() || '');
	if (!text || new TextEncoder().encode(text).length > 65536) return null;
	if (%s && ((field && !el.readOnly && !el.disabled) || el?.isContentEditable)) {
		if (!document.execCommand('delete')) return null;
	}
	return text;
})()""" % ("true" if code == KEY_X else "false")
	var response := await request("cdp", {"method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": true, "userGesture": true}})
	if response.has("error"):
		_clipboard_failed(str(response.error.get("message", "Chromium clipboard failed")))
		return
	var copied: Variant = response.get("result", {}).get("result", {}).get("value")
	if copied is String: DisplayServer.clipboard_set(copied)


func close() -> void:
	connection.remote_call(tab_id, "chromium.close", { "chromium": "%%%d" % session_id })


func release_rendering() -> void:
	# Run before removal: child viewports exit before their parent _exit_tree.
	texture = null
	changed.emit()
	_release_nv12()
	_reset_gpu()


func _exit_tree() -> void:
	_reset_gpu() # Detach retains the chromium process, cookies, and page state.


func _reset_gpu() -> void:
	gpu_generation += 1
	gpu_active = false
	gpu_frames = 0
	if gpu != null:
		gpu.close()
		gpu = null
	_drop_video_decoder()
	video_waiting_key = true
	pending_frame = PackedByteArray()


func reject_gpu(reason: String, notify_owner := true) -> void:
	_reset_gpu()
	gpu_error = reason
	print("[chromium gpu] ", reason)
	status = "Shared texture unavailable. Switching to video or PNG."
	if notify_owner and connection.connected:
		connection.send_action("chromium_gpu_reject", session_id)
	changed.emit()


func _gpu_current(generation: int, peer: RefCounted) -> bool:
	var transport := _gpu_transport()
	return is_inside_tree() and generation == gpu_generation and transport != null and transport.connected and transport.socket == peer


func _begin_gpu(generation: int, peer: RefCounted, transport: Node) -> void:
	# Only the common client's kernel peer check can authorize this path. Remote
	# WebSockets and byte-forwarded sockets continue using negotiated video.
	if not peer.has_method("local_peer_pid") or peer.local_peer_pid() <= 0:
		return
	var stream := preload("res://scenes/ChromiumGpuStream.gd").new()
	if not stream.start_shared(peer.local_peer_pid()):
		return
	gpu = stream
	gpu_error = ""
	var offer: Dictionary = await transport.request_action("chromium_gpu_offer", {
		"session": session_id, "mechanism": "d3d-shared-nt-v1" if OS.get_name() == "Windows" else "mach-iosurface-v1", "endpoint": stream.endpoint,
	})
	if not _gpu_current(generation, peer): return
	if offer.get("type") == "error":
		reject_gpu(str(offer.get("message", "Shared texture offer rejected")))
		return
	var deadline := Time.get_ticks_msec() + 4500
	while _gpu_current(generation, peer) and not stream.proof_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not _gpu_current(generation, peer): return
	if not stream.proof_ready():
		reject_gpu("Shared texture device proof timed out")
		return
	while _gpu_current(generation, peer) and Time.get_ticks_msec() < deadline:
		var confirmed: Dictionary = await transport.request_action("chromium_gpu_confirm", {"session": session_id})
		if not _gpu_current(generation, peer): return
		if confirmed.get("type") == "error":
			reject_gpu(str(confirmed.get("message", "Shared texture confirmation failed")))
			return
		if confirmed.get("result", {}).get("active", false):
			gpu_active = true
			_drop_video_decoder()
			pending_frame = PackedByteArray()
			video_waiting_key = true
			return
		await get_tree().process_frame
	if _gpu_current(generation, peer):
		reject_gpu("Shared texture confirmation timed out")


func can_open_native() -> bool:
	var transport := _gpu_transport()
	return super.can_open_native() and OS.get_name() in ["macOS", "Windows"] and transport != null and (
		transport.url == "shared://local" or transport.url.begins_with("ipc://")
	) and (OS.get_name() != "Windows" or gpu_active)


func open_native() -> void:
	if not can_open_native(): return
	if OS.get_name() == "Windows":
		ClassDB.instantiate("NativeWindowFrame").allow_foreground(pid)
	super.open_native()


func _input_viewport_size() -> Vector2:
	# CDP consumes logical page coordinates. Native capture and encoded video
	# can have a different physical extent at 150%/Retina display scaling.
	return super._input_viewport_size()
