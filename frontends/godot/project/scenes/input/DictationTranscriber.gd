extends Node
## One server-owned Live session per recording. Audio captured during setup is
## queued for at most five seconds, including recordings stopped before setup.
signal changed(text: String)
signal finished
signal failed(message: String)
var connection: Node
var pane_id := -1
var job := ""
var canceled := false
var stopping := false
var ended := false
var rate := 48000
var queued: Array[PackedByteArray] = []
var queued_bytes := 0
var offset := 0
var inflight: Dictionary = {}
var codec := DictationAudio.new()
var direct: Node
const ClientProvider := preload("res://scenes/input/ClientDictation.gd")

func start(sample_rate: int) -> void:
	rate = sample_rate
	if rate != 48000:
		_fail("Live Opus requires mono 48 kHz capture.")
		return
	var client_config := ClientProvider.credential()
	if client_config.has("error") or not str(client_config.get("password", "")).is_empty():
		direct = ClientProvider.new()
		add_child(direct)
		direct.changed.connect(func(text: String): changed.emit(text))
		direct.finished.connect(func(): ended = true; finished.emit())
		direct.failed.connect(func(message: String): _fail(message))
		direct.start(client_config)
		return
	if not is_instance_valid(connection) or not connection.connected:
		_fail("The dictation server is disconnected.")
		return
	connection.acknowledged.connect(_acknowledged)
	# Let begin finish even if canceled, so its newly allocated job can be closed.
	var response: Dictionary = await connection.remote_call(pane_id, "dictation.live.begin", {"format":"opus", "sample_rate":rate})
	job = str(response.get("result", {}).get("job", ""))
	if canceled:
		_cancel_job()
		ended = true
		return
	if response.has("error") or job.is_empty():
		_fail(str(response.get("error", {}).get("message", "Could not start live transcription.")))
		return
	for audio in queued:
		if canceled: break
		_upload(audio)
	queued.clear()
	queued_bytes = 0
	var finish_sent := false
	while not canceled:
		if stopping and not finish_sent:
			# Acknowledgements include every binary append, including the drained tail.
			if not inflight.is_empty():
				await get_tree().process_frame
				continue
			response = await connection.remote_call(pane_id, "dictation.live.finish", {"job":job,"offset":offset}, func(): return canceled)
			finish_sent = true
		else:
			response = await connection.remote_call(pane_id, "dictation.live.poll", {"job":job}, func(): return canceled)
		if canceled: break
		if response.has("error"):
			_fail(str(response.error.get("message", "Live transcription disconnected.")))
			return
		var result: Dictionary = response.get("result", {})
		changed.emit(str(result.get("text", "")))
		if result.get("error") != null:
			_fail(str(result.error))
			return
		if result.get("done", false):
			ended = true
			_cancel_job()
			finished.emit()
			return
		await get_tree().create_timer(.1).timeout
	ended = true

func accept(pcm: PackedByteArray) -> void:
	if canceled or ended or stopping: return
	if is_instance_valid(direct):
		direct.accept(pcm)
		return
	if job.is_empty():
		# Bound setup buffering by captured duration, not compressed size.
		queued_bytes += pcm.size()
		if queued_bytes > rate * 2 * 5:
			_fail("Live transcription connection took too long. Recording stopped.")
			return
	_encode(pcm, false)

func _encode(pcm: PackedByteArray, finish: bool) -> void:
	var result := codec.encode_live(pcm, finish)
	if result.has("error"):
		_fail(str(result.error))
		return
	var audio: PackedByteArray = result.audio
	if audio.is_empty(): return
	if job.is_empty(): queued.append(audio)
	else: _upload(audio)

func _upload(audio: PackedByteArray) -> void:
	# Five seconds of 100 ms batches plus the final codec flush.
	if inflight.size() >= 51:
		_fail("Live audio upload could not keep up.")
		return
	var ticket: int = connection.dictation_stream(pane_id, job, offset, audio)
	if ticket < 0:
		_fail("Live audio upload could not keep up.")
		return
	offset += audio.size()
	inflight[ticket] = Time.get_ticks_msec()

func _acknowledged(message: Dictionary) -> void:
	var ticket := int(message.get("request", -1))
	if not inflight.has(ticket): return
	inflight.erase(ticket)
	if message.get("type") == "error":
		_fail(str(message.get("error", {}).get("message", "Live audio upload failed.")))

func _process(_dt: float) -> void:
	if canceled or ended: return
	for sent_at in inflight.values():
		if Time.get_ticks_msec() - int(sent_at) > 5000:
			_fail("Live audio upload timed out.")
			return

func stop() -> void:
	if canceled or ended or stopping: return
	if is_instance_valid(direct):
		stopping = true
		direct.stop()
		return
	# Flush codec delay after the capture drain, before finish/acknowledgements.
	_encode(PackedByteArray(), true)
	stopping = true

func _fail(message: String) -> void:
	if canceled or ended: return
	cancel()
	failed.emit(message)

func _cancel_job() -> void:
	if is_instance_valid(connection) and not job.is_empty():
		connection.send_action("rpc", pane_id, {"method":"dictation.cancel", "params":{"job":job}})
	job = ""

func cancel() -> void:
	canceled = true
	if is_instance_valid(direct): direct.cancel()
	queued.clear()
	queued_bytes = 0
	inflight.clear()
	_cancel_job()

func _exit_tree() -> void:
	cancel()
	if is_instance_valid(connection) and connection.acknowledged.is_connected(_acknowledged): connection.acknowledged.disconnect(_acknowledged)
