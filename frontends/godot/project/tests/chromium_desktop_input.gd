extends "shared_chromium_gpu.gd"
## Real frontend input routing; no desktop-wide events or clipboard access.
## CDP sets up/observes the page, but never injects the input being tested.
var browser: Node
var pane: Control
var observations: Array = []
var decode_events: Array = []

func evaluate(expression: String) -> Variant:
	var response: Dictionary = await browser.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": expression, "returnByValue": true,
	}})
	return response.get("result", {}).get("result", {}).get("value")

func expect_page(expression: String, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	var value: Variant
	while Time.get_ticks_msec() < deadline:
		value = await evaluate(expression)
		if value == true:
			check(true, label)
			return true
		await process_frame
	check(false, label + ": " + str(value))
	return false

func click_element(id: String) -> void:
	var rect: Variant = await evaluate("(()=>{let r=document.getElementById(%s).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()" % JSON.stringify(id))
	if not check(rect is Array and rect.size() == 2, "Find input target: " + id): return
	await click(on(pane.texture, Vector2(rect[0], rect[1]) / Vector2(browser._preview_size)))

func shortcut(code: Key, shift := false) -> void:
	# Browser editing uses Ctrl, not the workspace Ctrl+Shift menu convention.
	var modifiers := {"cmd": OS.get_name() == "macOS", "ctrl": OS.get_name() != "macOS", "shift": shift}
	_send_key(code, 0, modifiers)
	await process_frame
	if code == KEY_A and not shift and OS.get_name() != "macOS":
		# Ctrl+A is the workspace prefix; repeat it to forward select-all.
		# On macOS, Cmd+A reaches the browser directly.
		check(host.prefix_commands.active, "First select-all key arms workspace prefix")
		_send_key(code, 0, modifiers)
		await process_frame
		check(not host.prefix_commands.active, "Repeated prefix forwards select-all and disarms")

func record(label: String) -> void:
	observations.append({"label": label, "page": await evaluate("({active:document.activeElement.id,first:first.value,second:second.value,readonly:locked.value,clicks,keys:seen,scrollY})"),
		"gpu_frames": browser.gpu_frames, "gpu_generation": browser.gpu_generation, "decoded_frames": decoded,
		"decode_events": decode_events.duplicate(true)})
	FileAccess.open(evidence.path_join("input.json"), FileAccess.WRITE).store_string(JSON.stringify(observations, "\t"))

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_GPU_EVIDENCE")
	await camera_at_rest()
	if not await prepare_test_display(host.get_window().current_screen, "initial"): return
	var owner: int = host.active_session_id
	var owner_pid: int = host.sessions[owner].term.get_shell_pid()
	browser = await host.create_chromium_session(OS.get_environment("GRAFFITTY_GPU_URL"))
	if not check(browser != null, "Private browser created for frontend input"): return
	browser.frame_decoded.connect(func(_image):
		decoded += 1
		decode_events.append({"at_ms": Time.get_ticks_msec(), "gpu_active": browser.gpu_active, "generation": browser.gpu_generation}))
	if not await until(func(): return browser.gpu_active and browser.gpu_frames > 0, "Input fixture imports real native GPU frames"): return
	var decoded_at_ready := decoded
	check(browser.texture is Texture2DRD, "Input fixture uses native texture presentation")
	var page := """<!doctype html><style>
	body{margin:0;height:2400px;background:linear-gradient(to right,#f020c0 50%,#20e0e0 50%);font:24px sans-serif}
	input,button{position:absolute;left:40px;width:320px;height:45px;font:24px sans-serif}
	#first{top:40px}#second{top:110px}#locked{top:180px}#button{top:250px}
	</style><input id=first><input id=second><input id=locked readonly value=immutable>
	<button id=button onclick="clicks++;document.title='clicked-'+clicks">Click</button>
	<script>window.clicks=0;window.seen=[];document.addEventListener('keydown',e=>seen.push({target:e.target.id,key:e.key,meta:e.metaKey,ctrl:e.ctrlKey,shift:e.shiftKey}));</script>"""
	check(await evaluate("document.open();document.write(%s);document.close();true" % JSON.stringify(page)) == true, "Real renderer loads input fixture")
	var key := "%%%d" % browser.session_id
	host.focus_pane(key)
	host.workspace_view.toggle_fit_pane(key)
	await camera_at_rest()
	pane = host.workspace_view.panes[key]
	await colors("input-initial", Color("f020c0"), Color("20e0e0"))
	await click_element("first")
	await expect_page("document.activeElement===first", "Pointer click focuses first browser field")
	await type("hello Chromium")
	await expect_page("first.value==='hello Chromium'", "Frontend keyboard events type into Chromium")
	await shortcut(KEY_A)
	await expect_page("first.selectionStart===0&&first.selectionEnd===first.value.length", "Native-platform select-all shortcut reaches browser")
	await type("Replacement")
	await expect_page("first.value==='Replacement'", "Typing replaces the selected browser text")
	await shortcut(KEY_Z)
	var undone := await expect_page("first.value==='hello Chromium'", "Native-platform undo restores browser text")
	await record("undo")
	if not undone: return
	await shortcut(KEY_Z, true)
	await expect_page("first.value==='Replacement'", "Native-platform redo restores replacement")
	await expect_page("seen.some(e=>e.key==='z'&&!e.shift&&(e.meta||e.ctrl))&&seen.some(e=>e.key==='z'&&e.shift&&(e.meta||e.ctrl))", "Undo and redo key events both reach the browser")
	await type("{tab}")
	await expect_page("document.activeElement===second", "Tab moves focus within browser rather than workspace")
	await type("Unicode café 한글")
	await expect_page("second.value==='Unicode café 한글'", "Unicode key events survive frontend input routing")
	_send_key(KEY_TAB, 0, {"shift": true})
	await expect_page("document.activeElement===first", "Shift-Tab returns browser focus")
	await shortcut(KEY_A)
	_send_key(KEY_RIGHT, 0, {})
	await type("{backspace}")
	await expect_page("first.value==='Replacemen'", "Editing keys modify only focused field")
	await expect_page("second.value==='Unicode café 한글'", "Focus switching preserves the other field")
	await click_element("locked")
	await shortcut(KEY_A)
	await type("discarded{backspace}")
	await expect_page("locked.value==='immutable'", "Read-only field rejects typed replacement and deletion")
	await click_element("button")
	await expect_page("clicks===1&&document.title==='clicked-1'", "Frontend click reaches DOM button")
	await record("editing")
	# Change the actual pane extent, not the browser's viewport behind its owner.
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	host.workspace_view.set_window_rect(key, Rect2(pane.position, Vector2(802, 602) + pane.size - pane.texture.size), true)
	await camera_at_rest()
	await colors("input-resized", Color("f020c0"), Color("20e0e0"))
	await click_element("button")
	await expect_page("clicks===2", "Pointer mapping follows resized browser pane")
	await point_at(on(pane.texture, Vector2(.75, .7)))
	await tap(MOUSE_BUTTON_WHEEL_DOWN)
	await expect_page("scrollY>0", "Frontend wheel scrolls the actual browser document")
	await tap(MOUSE_BUTTON_WHEEL_UP)
	await expect_page("scrollY===0", "Reverse wheel returns the document to its initial position")
	await record("resize-scroll")
	check(decoded == decoded_at_ready, "Editing, resize and scroll stay on native GPU without CPU decoding")
	var peer: RefCounted = browser.connection.socket
	var generation: int = browser.gpu_generation
	browser.connection.connect_shared(browser.connection.shared_options.duplicate(true))
	if not await until(func(): return browser.connection.socket != peer and browser.gpu_peer == browser.connection.socket and browser.gpu_generation > generation and browser.gpu_active and browser.gpu_frames > 0, "Input reconnect obtains fresh connection-bound GPU proof"): return
	# Video is permitted while the new connection proves its native device.
	# Once that proof/import completes, further input must remain GPU-native.
	var decoded_at_reconnect := decoded
	await record("reconnect-ready")
	await click_element("first")
	await shortcut(KEY_A)
	await type("after reconnect")
	await expect_page("first.value==='after reconnect'&&second.value==='Unicode café 한글'&&clicks===2", "Post-reconnect input reaches retained browser document")
	await colors("input-reconnected", Color("f020c0"), Color("20e0e0"))
	await record("reconnected")
	check(decoded == decoded_at_reconnect, "Post-reconnect input stays on native GPU without CPU decoding")
	check(host.sessions[owner].term.get_shell_pid() == owner_pid, "Input retains owning terminal process")
	var state: Dictionary = (await browser.request("chrome-state")).get("result", {})
	check(not browser.native_visible and int(state.get("visibleWindows", -1)) == 0, "Browser remains embedded throughout input")
	check(int(state.get("errors", -1)) == 0, "Browser host reports no capture errors")
