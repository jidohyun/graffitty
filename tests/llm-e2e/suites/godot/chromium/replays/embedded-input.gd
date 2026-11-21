extends "../../../../replay/replay.gd"

var chromium: Node
var pane: Control
var waiting_result: Dictionary = { }


func evaluate(expression: String) -> Variant:
	var response: Dictionary = await chromium.request("cdp", {
		"method": "Runtime.evaluate",
		"params": { "expression": expression, "returnByValue": true },
	})
	return response.get("result", {}).get("result", {}).get("value")


func page_point(point: Vector2) -> Vector2:
	return on(pane.texture, point / Vector2(chromium._preview_size))


func wait_for_click() -> void:
	waiting_result = await chromium.request("cdp", {
		"method": "Runtime.evaluate",
		"params": {
			"expression": "new Promise(resolve => b.addEventListener('click', () => resolve('clicked'), {once:true}))",
			"awaitPromise": true, "returnByValue": true,
		},
	}, 4000)


func page_strip() -> PackedByteArray:
	var image := root.get_texture().get_image()
	var ratio := Vector2(image.get_size()) / root.get_visible_rect().size
	var start := on(pane.texture, Vector2(.12, .1)) * ratio
	var end := on(pane.texture, Vector2(.15, .95)) * ratio
	return image.get_region(Rect2i(start, end - start)).get_data()


func bottom_marker() -> int:
	var image := root.get_texture().get_image()
	var ratio := Vector2(image.get_size()) / root.get_visible_rect().size
	var start := on(pane.texture, Vector2(.12, .1)) * ratio
	var end := on(pane.texture, Vector2(.12, .99)) * ratio
	for y in range(int(start.y), int(end.y)):
		var color := image.get_pixel(int(start.x), y)
		if color.r > .5 and color.g < .45 and color.b < .3:
			return y
	return -1


func windows_native_menu(select_all: bool) -> void:
	var label := "select-all" if select_all else "escape"
	var evidence := OS.get_environment("XDG_STATE_HOME").path_join("embedded-menu-" + label)
	DirAccess.make_dir_recursive_absolute(evidence)
	var spec := evidence.path_join("selection.json")
	var chosen := {"id": -1}
	pane.chromium_context_menu.id_pressed.connect(func(id):
		chosen.id = id
		print("NATIVE_MENU_CHOSEN ", id), CONNECT_ONE_SHOT)
	var prepare := func(value: Dictionary):
		var items: Array = value.get("items", [])
		var index := -1
		for i in items.size():
			if int(items[i].get("id", -1)) == 50156: index = i
		FileAccess.open(spec, FileAccess.WRITE).store_string(JSON.stringify({"index": index}))
	if select_all:
		# Write the command index before display() enters TrackPopupMenuEx.
		chromium.context_menu_requested.disconnect(pane.chromium_context_menu.display)
		chromium.context_menu_requested.connect(prepare, CONNECT_ONE_SHOT)
		chromium.context_menu_requested.connect(pane.chromium_context_menu.display)
	var helper: String = get_script().resource_path.get_base_dir().path_join("../../windows/replays/native-menu.py")
	OS.create_process("python", [ProjectSettings.globalize_path(helper), str(OS.get_process_id()), evidence, spec if select_all else "--escape"])
	await tap(MOUSE_BUTTON_RIGHT)
	var receipt := evidence.path_join("native-menu.json")
	var deadline := Time.get_ticks_msec() + 18000
	while not FileAccess.file_exists(receipt) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(FileAccess.file_exists(receipt), "Owned Windows context menu captured: " + label): return
	var result: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(receipt))
	var rect: Array = result.rect
	check(Vector2(rect[0], rect[1]).distance_to(chromium.context_menu_screen) <= 8,
		"Windows native menu opens at the clicked screen position with display scaling")
	if select_all:
		check(int(result.get("selected_index", -1)) >= 0 and chosen.id == 50156, "Native menu delivers Chromium's Select All command: " + str(chosen.id))
		var selected := false
		deadline = Time.get_ticks_msec() + 4000
		while not selected and Time.get_ticks_msec() < deadline:
			selected = bool(await evaluate("i.selectionEnd-i.selectionStart===i.value.length"))
			await process_frame
		check(selected, "Choosing the native menu action executes Chromium's Select All")
		print("NATIVE_MENU_SELECTION ", await evaluate("({start:i.selectionStart,end:i.selectionEnd,value:i.value,active:document.activeElement.id})"))
	else:
		await hold(.2)
		check(not pane.chromium_context_menu.visible, "Escape dismisses the Windows native context menu")


func macos_native_menu(at: Vector2) -> void:
	var directory := evidence_path("chromium-native-menu")
	DirAccess.make_dir_recursive_absolute(directory)
	var spec := directory.path_join("selection.json")
	var menu: PopupMenu = pane.chromium_context_menu
	var prepare := func(value: Dictionary):
		var index := 0
		var selected := -1
		for item in value.get("items", []):
			if not item.get("enabled", true) or int(item.get("type", 1)) == 4: continue
			if int(item.get("id", -1)) == 50156: selected = index
			index += 1
		FileAccess.open(spec, FileAccess.WRITE).store_string(JSON.stringify({"index": selected}))
	chromium.context_menu_requested.disconnect(menu.display)
	chromium.context_menu_requested.connect(prepare, CONNECT_ONE_SHOT)
	chromium.context_menu_requested.connect(menu.display)
	var helper: String = get_script().resource_path.get_base_dir().path_join("native-menu.swift")
	OS.create_process("/usr/bin/swift", [ProjectSettings.globalize_path(helper), str(OS.get_process_id()), directory, spec])
	await tap(MOUSE_BUTTON_RIGHT)
	var receipt := directory.path_join("native-menu.json")
	var deadline := Time.get_ticks_msec() + 20000
	while not FileAccess.file_exists(receipt) and Time.get_ticks_msec() < deadline: await process_frame
	if not check(FileAccess.file_exists(receipt), "Native AppKit menu helper completes"): return
	var result: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(receipt))
	check(result.get("native_keys", false), "Actual native keys select Chromium's menu command: " + JSON.stringify(result))
	var selected := false
	deadline = Time.get_ticks_msec() + 4000
	while not selected and Time.get_ticks_msec() < deadline:
		selected = bool(await evaluate("i.value.length>0&&i.selectionEnd-i.selectionStart===i.value.length"))
		await process_frame
	check(selected, "Native menu keyboard selection executes Chromium's Select All")
	check(menu.prefer_native_menu and menu.force_native, "Desktop uses the native AppKit context menu")
	check(chromium.context_menu_screen.distance_to(host.application.screen_point(root, at)) <= 8,
		"Native context menu uses the clicked screen position")


func play() -> void:
	await camera_at_rest()
	host.world.fx_enabled = false
	var html := """<!doctype html><style>
	body{margin:0;background:#183044;color:white;font:24px sans-serif;height:3000px}
	button,input,p{position:absolute;left:30px}
	button{top:30px;width:200px;height:45px}input{top:95px;width:260px;height:40px}
	p{top:155px;white-space:nowrap}
	</style><button id=b onclick="window.clicks++">Click me</button>
	<input id=i><p id=p>Select these words in Chromium.</p><div style="position:absolute;top:2900px;height:100px;width:100%;background:#c85020"></div>
	<script>window.clicks=0;window.contexts=0;
	document.addEventListener('contextmenu',e=>{if(!window.showDefaultMenu)e.preventDefault();window.contexts++});</script>"""
	chromium = await host.create_chromium_session("about:blank")
	if not check(chromium != null, "Shared owner creates the chromium fixture"):
		return
	var deadline := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < deadline:
		await process_frame
	check(chromium.chromium_ready, "Owned desktop Chromium starts")
	if not chromium.chromium_ready:
		return
	check(await evaluate("document.open();document.write(%s);document.close();true" % JSON.stringify(html)) == true,
		"Real Chromium loads the isolated input fixture")
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	var key := "%%%d" % chromium.session_id
	pane = host.workspace_view.panes[key]
	host.workspace_view.set_window_rect(key, Rect2(40, 100, 850, 650), true)
	host.workspace_view.toggle_fit_pane(key)
	await camera_at_rest()
	await hold(1.0)
	print("GPU_IMPORT_STATE ", {"active": chromium.gpu_active, "error": chromium.gpu_error, "frames": chromium.gpu_frames, "size": chromium.texture.get_size(), "preview": chromium._preview_size})
	check(root.get_texture().get_image().get_width() > 0 and chromium.gpu_active and chromium.gpu_frames > 0,
		"Real desktop window renders shared GPU chromium frames")
	await click(page_point(Vector2(110, 50)))
	check(await evaluate("window.clicks") == 1, "Pane click reaches Chromium button")
	await click(page_point(Vector2(120, 115)))
	await type("hello chromium")
	await hold(.3)
	check(await evaluate("i.value") == "hello chromium", "Focused pane receives keyboard text")
	var rect: Array = await evaluate("(()=>{let r=p.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()")
	await drag(page_point(Vector2(rect[0] + 2, rect[1] + rect[3] / 2)),
		page_point(Vector2(rect[0] + 250, rect[1] + rect[3] / 2)), .8)
	await hold(.2)
	check(str(await evaluate("getSelection().toString()")).length() > 5,
		"Actual pointer drag selects page text")
	await point_at(page_point(Vector2(400, 280)))
	await tap(MOUSE_BUTTON_RIGHT)
	check(await evaluate("window.contexts") == 1, "Right-click reaches page context menu handler")
	await evaluate("window.showDefaultMenu=true; true")
	var menu_at := page_point(Vector2(120, 115))
	await point_at(menu_at)
	if OS.get_name() == "Windows":
		await windows_native_menu(true)
		await point_at(menu_at)
		await windows_native_menu(false)
	elif OS.get_name() == "macOS":
		await macos_native_menu(menu_at)
	else:
		# Desktop shows Chromium's commands in a native OS menu. Without an
		# interactive session that menu closes at once, so choose a command
		# through the same id_pressed signal a native selection emits.
		var menu: PopupMenu = pane.chromium_context_menu
		var shown := {"items": []}
		var choose_select_all := func(value: Dictionary):
			if value.get("items", []).is_empty(): return
			shown.items = value.items
			# Chromium IDC_CONTENT_CONTEXT_SELECTALL; labels are localized.
			if menu.get_item_index(50156) >= 0: menu.id_pressed.emit(50156)
		check(not bool(await evaluate("i.value.length>0&&i.selectionEnd-i.selectionStart===i.value.length")), "The input is not already fully selected")
		chromium.context_menu_requested.connect(choose_select_all)
		await tap(MOUSE_BUTTON_RIGHT)
		var menu_deadline := Time.get_ticks_msec() + 4000
		while shown.items.is_empty() and Time.get_ticks_msec() < menu_deadline:
			await process_frame
		chromium.context_menu_requested.disconnect(choose_select_all)
		check(not shown.items.is_empty(), "Chromium supplies its context menu to the owning pane")
		check(menu.prefer_native_menu and menu.force_native, "Desktop shows Chromium's context menu as a native menu")
		check(chromium.context_menu_screen.distance_to(host.application.screen_point(root, menu_at)) <= 8,
			"Native context menu uses the clicked screen position")
		check(shown.items.any(func(item): return int(item.get("id", -1)) == 50156), "Chromium supplies the input's Select All command")
		var selected := false
		menu_deadline = Time.get_ticks_msec() + 4000
		while not selected and Time.get_ticks_msec() < menu_deadline:
			selected = bool(await evaluate("i.value.length>0&&i.selectionEnd-i.selectionStart===i.value.length"))
			await process_frame
		check(selected, "Choosing the menu action executes Chromium's Select All")
	await evaluate("window.showDefaultMenu=false; true")
	await point_at(page_point(Vector2(400, 280)))
	await tap(MOUSE_BUTTON_WHEEL_DOWN)
	await hold(.4)
	check(float(await evaluate("scrollY")) > 0, "Actual wheel input scrolls Chromium")
	await tap(MOUSE_BUTTON_WHEEL_UP)
	await hold(.4)
	host.workspace_view.set_window_rect(key, Rect2(40, 100, 650, 500), true)
	await camera_at_rest()
	await hold(.6)
	await click(page_point(Vector2(110, 50)))
	check(await evaluate("window.clicks") == 2, "Click mapping follows resized chromium viewport")
	wait_for_click()
	await hold(.3)
	await click(page_point(Vector2(110, 50)))
	var input_deadline := Time.get_ticks_msec() + 3000
	while waiting_result.is_empty() and Time.get_ticks_msec() < input_deadline:
		await process_frame
	check(waiting_result.get("result", {}).get("result", {}).get("value") == "clicked",
		"Input completes while an automation command awaits the click")
	await point_at(page_point(Vector2(400, 280)))
	for step in 45:
		await tap(MOUSE_BUTTON_WHEEL_DOWN)
		await hold(.02)
	await hold(.5)
	var bottom: float = float(await evaluate("scrollY"))
	check(bool(await evaluate("Math.abs(scrollY + innerHeight - document.documentElement.scrollHeight) <= 1")), "Wheel reaches document bottom")
	var stable: PackedByteArray = page_strip()
	for step in 5:
		await tap(MOUSE_BUTTON_WHEEL_DOWN)
		await hold(.05)
	check(page_strip() == stable, "Discrete wheel at bottom does not restart a rubber-band animation")
	var trace: Array[int] = []
	var baseline := bottom_marker()
	for step in 24:
		var gesture := InputEventPanGesture.new()
		gesture.device = REPLAY_POINTER_DEVICE
		gesture.position = page_point(Vector2(400, 280))
		# Real vertical trackpad motion contains fractional horizontal noise.
		# An integer-varargs ABI mismatch used to turn it into enormous X motion.
		gesture.delta = Vector2(.001 if step % 2 == 0 else -.001, .5)
		# Same payload as AppKit -> Rust: finger phases and the event's own time.
		# Unphased scrolling stops at the edge instead of stretching.
		gesture.set_meta("scroll_phase", "began" if step == 0 else "changed")
		gesture.set_meta("event_time", Time.get_ticks_usec() / 1000000.0)
		root.push_input(gesture, true)
		await hold(.025)
		trace.append(bottom_marker())
	var during := trace.duplicate()
	# The fingers lift: a zero-travel end lets the page spring back.
	var lift := InputEventPanGesture.new()
	lift.device = REPLAY_POINTER_DEVICE
	lift.position = page_point(Vector2(400, 280))
	lift.delta = Vector2.ZERO
	lift.set_meta("scroll_phase", "ended")
	lift.set_meta("event_time", Time.get_ticks_usec() / 1000000.0)
	root.push_input(lift, true)
	for step in 45:
		await hold(.025)
		trace.append(bottom_marker())
	print("BOUNCE_TRACE baseline=", baseline, " positions=", trace)
	check(baseline >= 0 and trace.all(func(y): return y >= 0), "Bounce marker stays visible throughout the gesture")
	var minimum: int = trace.min()
	var reversals := 0
	for step in range(1, during.size()):
		if during[step] > during[step - 1] + 2:
			reversals += 1
	var backend: String = str((await chromium.request("chrome-state")).get("result", {}).get("backend", ""))
	if OS.get_name() == "macOS" and backend == "chrome":
		check(minimum < baseline - 3, "Continuous trackpad gesture visibly stretches the page at bottom")
	else:
		print("NOT_APPLICABLE: native rubber-band stretch (%s on %s); bottom pixels stay stable" % [backend, OS.get_name()])
		check(trace.all(func(y): return absi(y - baseline) <= 1), "Continuous scrolling at the boundary keeps pixels stable without a native rubber band")
	check(reversals <= 1, "Continuous gesture does not repeatedly restart the spring")
	check(absi(trace[-1] - baseline) <= 1, "Rubber-band settles back to the original page pixels")
	check(float(await evaluate("scrollY")) == bottom, "Bottom overscroll leaves document position unchanged")
	var state: Dictionary = (await chromium.request("chrome-state")).get("result", {})
	print("EMBEDDED_STATE ", state)
	check(not chromium.native_visible, "Interaction keeps Chromium embedded")
	for counter in ["visibleWindows", "unexpectedWindowOrders", "unexpectedKeyEvents", "unexpectedActivations", "errors"]:
		check(int(state.get(counter, -1)) == 0, "%s stays zero during embedded input" % counter)
	chromium.close()
