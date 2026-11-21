extends SceneTree
## Driven by headless_chromium_e2e.py against its real Chromium/server fixture.
var connection: Node
var chromium: Node
var failures: Array[String] = []
var decoded: Image

func _initialize() -> void:
	run.call_deferred()

func expect(value: bool, message: String) -> void:
	print("%s %s" % ["PASS" if value else "FAIL", message])
	if not value: failures.append(message)

func until(check: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while not check.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return check.call()

func evaluate(expression: String) -> Variant:
	var result: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": true}})
	if result.has("error"):
		expect(false, str(result.error))
		return null
	return result.result.result.get("value")

func mouse(at: Vector2, pressed: bool, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.pressed = pressed
	event.button_index = button
	chromium.remote_input(event, Vector2(1200, 1000))

func key(code: int, unicode_value := 0) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.unicode = unicode_value
		event.pressed = pressed
		chromium.remote_input(event, Vector2(1200, 1000))

func chord(code: int, meta := false, alt := false, shift := false, ctrl := false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.meta_pressed = meta
		event.alt_pressed = alt
		event.shift_pressed = shift
		event.ctrl_pressed = ctrl
		event.pressed = pressed
		chromium.remote_input(event, Vector2(1200, 1000))

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	connection = preload("res://scenes/remote/RemoteConnection.gd").new()
	# Federated/mobile clients translate IDs and cross the native JSON boundary.
	connection.namespace_ids = true
	root.add_child(connection)
	connection.stream_quality = {"max_height": 360, "fps": 30, "bitrate_kbps": 2000}
	connection.connect_remote(descriptor.url, descriptor.token)
	expect(await until(func(): return connection.connected), "Godot connects")
	chromium = preload("res://scenes/remote/RemoteChromiumSession.gd").new()
	chromium.connection = connection
	chromium.tab_id = connection.local_id(int(args[1]))
	chromium.session_id = connection.local_id(int(args[2]))
	chromium.chromium_ready = true
	# A real workspace supplies the logical pane extent, independently of video.
	chromium.set_preview_size(Vector2(1000, 700))
	chromium.frame_decoded.connect(func(image: Image): decoded = image)
	root.add_child(chromium)
	connection.changed.connect(func():
		for entry in connection.topology.get("chromiums", []):
			if int(entry.id) == chromium.session_id: chromium.apply_state(entry.state))
	connection.chromium_video_received.connect(func(id, header, data):
		if id == chromium.session_id: chromium.apply_video_frame(header, data))
	connection.subscribe([chromium.session_id])
	expect(await until(func(): return chromium.texture != null), "Pushed chromium frame decoded")
	if not preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs().is_empty():
		expect(chromium.video_codec in ["hevc", "av1", "h264"], "Negotiated hardware video replaces screenshot frames")
		expect(chromium.texture.get_height() <= 360 and chromium._input_viewport_size().y == 700, "Downscaled stream retains original page coordinates")
	print("Negotiated codec: ", chromium.video_codec)
	await evaluate("document.body.style.background='rgb(20,80,160)'; true")
	expect(await until(func():
		var pixel: Color = decoded.get_pixel(decoded.get_width() - 10, decoded.get_height() - 10)
		return absf(pixel.r - 20.0/255) < .08 and absf(pixel.g - 80.0/255) < .08 and absf(pixel.b - 160.0/255) < .08),
		"Direct GPU video preserves RGB colors")
	var original: Dictionary = await chromium.request("chrome-state")
	var original_id: int = int(original.result.chromiumId)
	await chromium.request("tab-new", {"url":"about:blank"})
	await evaluate("document.body.style.background='rgb(180,40,20)'; document.body.style.height='4000px'; true")
	expect(await until(func():
		var pixel: Color = decoded.get_pixel(decoded.get_width() - 10, decoded.get_height() - 10)
		return pixel.r > .6 and pixel.g < .25 and pixel.b < .2), "New tab switches the GPU capture target")
	mouse(Vector2(800, 500), true, MOUSE_BUTTON_WHEEL_DOWN)
	await create_timer(.25).timeout
	expect(await evaluate("scrollY > 0"), "Native scroll reaches the newly selected remote tab")
	await chromium.request("tab-select", {"chromium_id":original_id})
	expect(await until(func():
		var pixel: Color = decoded.get_pixel(decoded.get_width() - 10, decoded.get_height() - 10)
		return absf(pixel.b - 160.0/255) < .08 and pixel.r < .2), "Selecting the original tab restores its GPU frame")
	await evaluate("document.body.innerHTML='<input id=field style=\"position:absolute;left:100px;top:100px;width:300px;height:50px\"><div style=\"height:4000px\"></div>'; window.clicks=[]; window.keys=[]; document.addEventListener('mousedown',e=>clicks.push([e.clientX,e.clientY,e.button])); document.addEventListener('keydown',e=>keys.push(e.key)); true")
	# 1000x700 frame fitted into 1200x1000 => scale 1.2, vertical offset 80.
	mouse(Vector2(240, 230), true)
	mouse(Vector2(240, 230), false)
	key(KEY_A, 97)
	key(KEY_B, 98)
	key(KEY_BACKSPACE)
	key(KEY_NONE, 0xD55C)
	key(KEY_ENTER)
	await create_timer(.2).timeout
	expect(await evaluate("field.value") == "a한", "Click focuses field; Unicode typing and Backspace work")
	print("Pointer coordinates: ", await evaluate("clicks[0]"), " frame: ", chromium.texture.get_size())
	expect(await evaluate("Math.abs(clicks[0][0]-200)<=1 && Math.abs(clicks[0][1]-125)<=1"), "Letterbox coordinates reach Chromium in page pixels")
	expect(await evaluate("keys.includes('Enter')"), "Enter reaches Chromium")
	mouse(Vector2(240, 230), true, MOUSE_BUTTON_RIGHT)
	mouse(Vector2(240, 230), false, MOUSE_BUTTON_RIGHT)
	await create_timer(.1).timeout
	expect(await evaluate("clicks.some(e=>e[2]===2)"), "Right click reaches Chromium")
	if OS.get_name() == "macOS":
		expect(await until(func(): return not chromium._context_menu.get("items", []).is_empty()),
			"Remote context menu reaches the requesting client")
		var command_id := -1
		for item in chromium._context_menu.get("items", []):
			if str(item.label).to_lower().replace("&", "") == "select all": command_id = int(item.id)
		expect(command_id >= 0, "Remote Chromium supplies the native Select All command")
		if command_id >= 0:
			await chromium.request("context-menu-select", {"menu_id":chromium._context_menu.id, "command_id":command_id})
			expect(bool(await evaluate("field.selectionEnd-field.selectionStart===field.value.length")),
				"Remote menu selection executes in Chromium")
	if OS.get_name() == "macOS":
		# AppKit text bindings, which CDP key events only get as edit commands.
		var end_at := "field.value='one two three';field.focus();field.setSelectionRange(13,13);true"
		var mid_at := "field.value='one two three';field.focus();field.setSelectionRange(5,5);true"
		for case in [
			["⌥←", end_at, KEY_LEFT, false, true, false, false, ["one two three", 8, 8]],
			["⌥⌫", end_at, KEY_BACKSPACE, false, true, false, false, ["one two ", 8, 8]],
			["⌘←", end_at, KEY_LEFT, true, false, false, false, ["one two three", 0, 0]],
			["⌘→", mid_at, KEY_RIGHT, true, false, false, false, ["one two three", 13, 13]],
			["⇧⌘←", end_at, KEY_LEFT, true, false, true, false, ["one two three", 0, 13]],
			["⌘↑", end_at, KEY_UP, true, false, false, false, ["one two three", 0, 0]],
			["⌘↓", mid_at, KEY_DOWN, true, false, false, false, ["one two three", 13, 13]],
			["⌘⌫", end_at, KEY_BACKSPACE, true, false, false, false, ["", 0, 0]],
			["⌃A", mid_at, KEY_A, false, false, false, true, ["one two three", 0, 0]],
			["⌃E", mid_at, KEY_E, false, false, false, true, ["one two three", 13, 13]],
			["⌃K", mid_at, KEY_K, false, false, false, true, ["one t", 5, 5]],
		]:
			await evaluate(case[1])
			chord(case[2], case[3], case[4], case[5], case[6])
			await create_timer(.15).timeout
			var state: Variant = await evaluate("[field.value, field.selectionStart, field.selectionEnd]")
			expect(JSON.stringify(state) == JSON.stringify(case[7]), "%s edits like macOS: %s" % [case[0], JSON.stringify(state)])
	# Find in page runs in Chromium's own engine; results return through state.
	await evaluate("document.body.insertAdjacentHTML('afterbegin','<p id=hay>needle one Needle two needle</p>');true")
	var selected := "(()=>{const s=getSelection();return s.rangeCount?[String(s),s.getRangeAt(0).startOffset]:null})()"
	# Find as you type: each longer query must not step past the previous one's match.
	for query in ["n", "ne", "nee", "need", "needl", "needle"]:
		chromium.find(query)
		await create_timer(.12).timeout
	expect(await until(func(): return chromium.find_result.get("count") == 3 and chromium.find_result.get("active") == 1),
		"Typing a query keeps the first match active: %s" % JSON.stringify(chromium.find_result))
	chromium.stop_finding()
	await create_timer(.3).timeout
	expect(JSON.stringify(await evaluate(selected)) == '["needle",0]', "The reported first match is the one Chromium selects")
	await evaluate("getSelection().removeAllRanges();true")
	chromium.find("needle")
	expect(await until(func(): return chromium.find_result.get("count") == 3 and chromium.find_result.get("final") == true),
		"Chromium find in page counts every match: %s" % JSON.stringify(chromium.find_result))
	expect(chromium.find_result.get("active") == 1, "The first match is active")
	chromium.find("needle", false, true)
	expect(await until(func(): return chromium.find_result.get("active") == 2), "Find next moves to the second match")
	chromium.find("needle", true, true)
	expect(await until(func(): return chromium.find_result.get("active") == 1), "Find previous returns to the first match")
	chromium.stop_finding()
	expect(chromium.find_result.is_empty(), "Stopping clears the client's find result")
	await create_timer(.3).timeout
	expect(JSON.stringify(await evaluate(selected)) == '["needle",0]', "Closing find keeps the active match selected, like Chrome")
	expect(chromium.find_result.is_empty(), "The server does not resend a stopped find result")
	chromium.find("absent-needle")
	expect(await until(func(): return chromium.find_result.get("count") == 0 and chromium.find_result.get("final") == true),
		"A missing query reports zero matches")
	chromium.stop_finding(true)
	await evaluate("document.getElementById('hay').remove();true")
	mouse(Vector2(800, 500), true, MOUSE_BUTTON_WHEEL_DOWN)
	await create_timer(.2).timeout
	expect(await evaluate("scrollY > 0"), "Wheel scroll reaches Chromium")
	await evaluate("window.moves=[]; document.addEventListener('mousemove',e=>moves.push(e.buttons)); window.released=false; document.addEventListener('mouseup',()=>released=true); true")
	mouse(Vector2(800, 500), true)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(810, 510)
	chromium.remote_input(motion, Vector2(1200, 1000))
	await process_frame
	chromium.release_input()
	await create_timer(.1).timeout
	expect(await evaluate("moves.includes(1) && released"), "Drag carries held buttons; focus loss releases them")
	var before: int = chromium.frames
	await evaluate("window.anim=setInterval(()=>document.body.style.background='rgb('+Math.floor(Math.random()*255)+',0,0)',20); true")
	await create_timer(.6).timeout
	print("Pushed frames in 600 ms: ", chromium.frames - before)
	expect(chromium.frames - before >= 4, "Changing page pushes successive frames")
	await evaluate("clearInterval(anim); true")
	before = chromium.frames
	for codec in ["av1", "hevc", "h264"]:
		connection.reject_chromium_codec(chromium.session_id, codec)
	expect(await until(func(): return chromium.video_codec.is_empty() and chromium.frames > before),
		"Decoder exhaustion switches existing texture to explicit PNG fallback")
	expect(chromium.texture.get_image().get_format() == Image.FORMAT_RGBA8,
		"Video and compatibility frames retain the same pixel format")
	connection.disconnect_remote()
	chromium.queue_free()
	connection.queue_free()
	await process_frame
	print("REMOTE_CHROMIUM_INPUT_PASS" if failures.is_empty() else "REMOTE_CHROMIUM_INPUT_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
