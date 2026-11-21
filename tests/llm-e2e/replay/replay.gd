extends SceneTree
## A replay drives the real application the way a person would, at a person's
## pace, with the pointer, clicks and keys drawn on screen, so its Movie Maker
## recording reads like a screen recording.
##
## Each replay mirrors one case in tests/llm-e2e/suites/ and says its steps in
## that case's words. The case is the truth; a replay is a reusable script
## that can fall behind it.
##
##     godot --path . --script tests/llm-e2e/suites/<suite>/replays/<case>.gd -- --shell=/bin/sh
##     godot --path . --write-movie out.mp4 --fixed-fps 30 --script ... -- --record
##
## Without --record it runs as a test, as fast as the app allows; --record paces
## it like a person for a recording (--replay-speed=N speeds that up).
const Overlay := preload("overlay.gd")
const Background := preload("background.gd")
var overlay: Control
var host: Node
var app: Node
var failures: Array[String] = []
## By default a replay is a test and runs as fast as the app allows. With
## --record it moves like a person, so its recording can be watched.
var recording := false
var speed := 1.0
var _held := 0
const REPLAY_POINTER_DEVICE := 0xC0DE

func evidence_path(name: String) -> String:
	# Godot's Windows OS cache directory ignores XDG_CACHE_HOME. Keep captures
	# inside the runner's private evidence tree when one is configured.
	var directory := OS.get_environment("XDG_CACHE_HOME")
	if directory.is_empty(): directory = OS.get_cache_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	return directory.path_join(name)


## Keep physical mouse motion from changing GUI hover / button capture while
## the user continues working beside a recorded replay window.
class PointerGuard extends Node:
	func _input(event: InputEvent) -> void:
		if event is InputEventMouse and event.device != 0xC0DE:
			get_viewport().set_input_as_handled()



## Script errors stop a replay's steps silently; they must fail it instead.
class ErrorWatch extends Logger:
	var errors: Array[String] = []


	func _log_error(
		_function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_backtraces: Array[ScriptBacktrace],
	) -> void:
		if error_type in [ERROR_TYPE_SCRIPT, ERROR_TYPE_ERROR, ERROR_TYPE_SHADER]:
			errors.append(
				"%s:%d %s"
				% [file.get_file(), line, rationale if not rationale.is_empty() else code]
			)


	func _log_message(_message: String, _error: bool) -> void:
		pass


var _errors := ErrorWatch.new()
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()


func _initialize() -> void:
	diagnostic_guard.install(self)
	Background.install(self)
	DirAccess.make_dir_recursive_absolute(OS.get_cache_dir())
	OS.add_logger(_errors)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--replay-speed="):
			speed = maxf(float(arg.get_slice("=", 1)), 0.01)
		if arg == "--record":
			recording = true
	OS.set_environment(
		"XDG_CONFIG_HOME",
		OS.get_cache_dir().path_join("graffitty-replay-%d" % OS.get_process_id()),
	)
	_start.call_deferred()


func _start() -> void:
	if DisplayServer.get_name() == "headless":
		# A headless window is 64 pixels square; desktop distances such as the
		# pull that tears a tab off would span all of it. Give it the size a
		# window opens at.
		root.size = Vector2i(
			ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"),
		)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	# Replays share this explicitly named fixture workspace with remote clients.
	# Ordinary launches intentionally create fresh sessions.
	wrapper.launch_args = OS.get_cmdline_user_args()
	if OS.get_environment("GRAFFITTY_REPLAY_FRESH_SESSION") != "1":
		wrapper.launch_args += PackedStringArray(["--workspace=main"])
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 20000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null:
		printerr("Shared session startup failed: ", wrapper.status.text)
		quit(1)
		return
	host = wrapper.host
	root.add_child(PointerGuard.new())
	app = host.application
	app.scripted_pointer = true
	if recording:
		# Background recording has no native focus, but its presented active
		# tab is what the viewer sees. Use the same rule for both unread dots.
		app.agent_attention.in_view = func(view): return view == host and view.presentation_active
		app.agent_attention.refresh()
	if DisplayServer.get_name() != "headless":
		# Apply after host registration, which configures desktop DPI scaling. Keep
		# logical test coordinates stable when the desktop tiling manager resizes
		# this background window. Movie Maker also requires a fixed render size.
		#
		# Explicit resize cases change content_scale_size.
		root.content_scale_factor = 1.0
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
		root.content_scale_size = Vector2i(
			ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"),
		)
	_pointer_in_window()
	_stay_awake()
	# Headful replays return focus to the person's application, while staying
	# uncovered so macOS continues presenting them. Background replays render
	# hidden textures through their own scheduler and never change OS focus.
	var person := OS.get_environment("REPLAY_RETURN_FOCUS")
	if DisplayServer.get_name() != "headless" and not Background.enabled():
		root.always_on_top = true
	if not Background.requested() and not person.is_empty() and OS.get_name() == "macOS":
		OS.create_process("osascript", ["-e", 'tell application id "%s" to activate' % person])
	var layer := CanvasLayer.new()
	layer.layer = 128
	root.add_child(layer)
	overlay = Overlay.new()
	layer.add_child(overlay)
	await wait(1.0)
	if not keeps_floating_menu(): _park_floating_menu()
	await play()
	finish()


## Windows and Linux show the menu as a floating pill at the top centre, above
## the workspace, where it covers pane header controls near the middle of the
## window. A person drags it aside. A replay parks it in the bottom-left corner
## so that its clicks reach the headers it aims at; one that checks the pill's
## own default place returns true here.
func keeps_floating_menu() -> bool:
	return false


func _park_floating_menu() -> void:
	# The touch profile lays its floating controls out as a set; leave those.
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls(): return
	for menu in root.find_children("MobileMenu", "", true, false):
		var mover: Node = menu.get("mover")
		if mover == null or not mover.entries.has("menu"): continue
		mover.entries["menu"].anchor = Vector2(0, 1)
		# Saved as a person's drag is: the layout is reloaded from the saved
		# profile (a resized window, a new window's menu), which would
		# otherwise put the pill back at the top centre.
		mover._save("menu", Vector2(0, 1))
		mover.layout()


## Overridden by each replay.
func play() -> void:
	pass

# --- pacing -------------------------------------------------------------------


## Holds still for as long as the app needs, whatever the replay speed: a
## hover that opens a tab counts the app's own time.
func hold(seconds: float) -> void:
	var until: float = overlay.clock + seconds
	while overlay.clock < until:
		await process_frame


## False while a scenario means to act before the app is at rest, such as
## adding a tab while another is still sliding in.
var waits_for_rest := true


## Pacing for a viewer: a person's pauses when recording; when testing, as
## long as the app needs to catch up.
##
## That is two frames, and then until the app is done with what the last step
## started: no tab still sliding into place, no workspace change still on its
## way to the server. A step that follows reads where things are, and two
## frames are less time at a higher frame rate: counting frames alone aimed
## drags at tabs in mid-slide and read a move before it had happened.
func wait(seconds: float) -> void:
	var until: float = overlay.clock + _pace(seconds)
	var frames := 0
	while overlay.clock < until or frames < 2:
		await process_frame
		frames += 1
	if not waits_for_rest: return
	var deadline := Time.get_ticks_msec() + 3000
	var quiet := 0
	while quiet < 2 and Time.get_ticks_msec() < deadline:
		quiet = 0 if _app_catching_up() else quiet + 1
		if quiet < 2: await process_frame


func _app_catching_up() -> bool:
	if not is_instance_valid(app): return false
	for window in app.hosts:
		if not is_instance_valid(window): continue
		var backend: Variant = window.get("session_backend")
		if backend != null and backend.has_method("work_pending") and backend.work_pending(): return true
		if not is_instance_valid(window.get("workspace_view")): continue
		var bar: Variant = window.workspace_view.get("tab_bar")
		if is_instance_valid(bar) and is_instance_valid(bar.tabs) and not bar.tabs._bounds_animations.is_empty():
			return true
	return false


func _pace(seconds: float) -> float:
	return seconds / speed if recording else 0.0


func say(step: String) -> void:
	overlay.step = step
	print("[replay] ", step)
	await wait(0.8)

# --- pointer ------------------------------------------------------------------


## Keys and gestures go through Input, as the OS delivers them, so the app's
## own queries (Escape held, a pinch) see them.
##
## Input carries window pixels; the window turns them back into its own
## coordinates. The pointer goes to the window directly: Godot ignores Input's
## pointer while the real one is away.
func _to_window(point: Vector2) -> Vector2:
	return root.get_final_transform() * point


func _motion(at: Vector2, relative: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.device = REPLAY_POINTER_DEVICE
	motion.position = at
	motion.global_position = at
	motion.relative = relative
	motion.button_mask = _held
	root.push_input(motion, true)


## A native window finds controls under the pointer only while the OS reports
## the real mouse over it.
##
## A window that hosts its subwindows follows the pointer's events instead, so
## a replay's window does, and the real mouse stays free.
##
## Windows the app opens then appear inside the recording; the e2e cases, run
## on the real application, remain the truth for native windows.
func _pointer_in_window() -> void:
	root.gui_embed_subwindows = true


## Native subwindows, as the desktop application has them.
##
## While the replay's window hosts its subwindows, each floating control keeps
## an embedded catcher window over its button (the Windows and Linux menu is
## one), and Godot refuses to leave embedding while such a window is shown.
func native_subwindows() -> void:
	for catcher in root.find_children("FloatingCatcher_*", "Window", true, false):
		catcher.get_parent()._catchers.erase(str(catcher.name).trim_prefix("FloatingCatcher_"))
		catcher.hide()
		catcher.queue_free()
	root.gui_embed_subwindows = false


## Glides the pointer to a point in window pixels along a gentle arc.
func point_at(target: Vector2, seconds := 0.7) -> void:
	_pointer_in_window()
	var start: Vector2 = overlay.pointer if overlay.pointer.x >= 0 else root.get_visible_rect().size * 0.5
	# A hand moving freely curves a little, toward the middle of the window.
	# Holding a button it aims straight, as the cases ask ("at an even pace").
	var bend := (target - start).orthogonal().normalized() * minf(
		24.0,
		start.distance_to(target) * 0.05,
	)
	var middle := root.get_visible_rect().get_center()
	if bend.dot(middle - (start + target) * 0.5) < 0.0:
		bend = -bend
	if _held != 0:
		bend = Vector2.ZERO
	var begun: float = overlay.clock
	var last := start
	# A test still moves in steps, so drags and hovers see the pointer travel.
	var duration := _pace(seconds) if recording else 0.1
	while true:
		var t := clampf((overlay.clock - begun) / maxf(duration, 0.01), 0.0, 1.0)
		var eased := t * t * (3.0 - 2.0 * t)
		var at := start.lerp(target, eased) + bend * sin(PI * eased)
		overlay.pointer = at
		_motion(at, at - last)
		last = at
		if t >= 1.0:
			break
		await process_frame


## Pan through the application's right-button navigation gesture.
## Positive delta moves the camera right/down, so the pointer moves oppositely.
func pan_pixels(delta: Vector2) -> void:
	await press(MOUSE_BUTTON_RIGHT)
	await point_at(overlay.pointer - delta)
	await release(MOUSE_BUTTON_RIGHT)


## Send input directly to the application. The replay neither takes nor
## needs desktop keyboard focus.
##
## For held buttons, the app reads the replay's state just as it reads
## the OS pointer during normal use.
func press(button := MOUSE_BUTTON_LEFT) -> void:
	_motion(overlay.pointer, Vector2.ZERO)
	_held |= 1 << (button - 1)
	overlay.pressed = true
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = button
	event.pressed = true
	event.position = overlay.pointer
	event.global_position = overlay.pointer
	event.button_mask = _held
	root.push_input(event, true)
	await wait(0.12)


func release(button := MOUSE_BUTTON_LEFT, pause := 0.15) -> void:
	# Refresh ordinary click hover after native window events. A drag release
	# must not invent another movement: a typing camera can move underneath
	# the stationary pointer and silently replace the last visible preview.
	if app.drag.is_empty() and host.workspace_view.moving.is_empty():
		_motion(overlay.pointer, Vector2.ZERO)
	_held &= ~(1 << (button - 1))
	overlay.pressed = false
	overlay.ripple(overlay.pointer)
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = button
	event.pressed = false
	event.position = overlay.pointer
	event.global_position = overlay.pointer
	event.button_mask = _held
	root.push_input(event, true)
	if pause > 0.0:
		await wait(pause)


## A quick click where the pointer is, with no pause after it, for watching
## the frames that follow it.
func tap(button := MOUSE_BUTTON_LEFT) -> void:
	overlay.ripple(overlay.pointer)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.device = REPLAY_POINTER_DEVICE
		event.button_index = button
		event.pressed = down
		event.position = overlay.pointer
		event.global_position = overlay.pointer
		event.button_mask = _held | (1 << (button - 1)) if down else _held
		root.push_input(event, true)


func click(target: Vector2) -> void:
	await point_at(target)
	await press()
	await release()


func drag(from: Vector2, to: Vector2, seconds := 1.2) -> void:
	await point_at(from)
	await press()
	await point_at(to, seconds)
	await release()


func pan_view(delta: Vector2) -> void:
	# Right-drag pans; Command/Ctrl scrolling now zooms.
	overlay.key("right-drag pan")
	var frame := root.get_visible_rect()
	var origin := frame.get_center()
	# Re-grab for long pans, like a person: dragging beyond the native window
	# stops delivering GUI motion and cannot center a distant stashed pane.
	var strokes := maxi(1, ceili(delta.length() / (minf(frame.size.x, frame.size.y) * 0.25)))
	for stroke in strokes:
		await point_at(origin)
		await press(MOUSE_BUTTON_RIGHT)
		for i in 12:
			await point_at(origin - delta / strokes * float(i + 1) / 12.0)
		await release(MOUSE_BUTTON_RIGHT)


## A trackpad pinch where the pointer is: factor above 1 zooms in.
func pinch(factor: float, seconds := 0.8) -> void:
	overlay.key("pinch %s" % ("in" if factor > 1.0 else "out"))
	var steps := maxi(int(_pace(seconds) * 30.0), 4)
	for i in steps:
		var gesture := InputEventMagnifyGesture.new()
		gesture.factor = pow(factor, 1.0 / steps)
		gesture.position = _to_window(overlay.pointer)
		Input.parse_input_event(gesture)
		await process_frame

# --- keyboard -----------------------------------------------------------------

const NAMED := {
	"enter": [KEY_ENTER, "↵"],
	"tab": [KEY_TAB, "⇥"],
	"escape": [KEY_ESCAPE, "esc"],
	"backspace": [KEY_BACKSPACE, "⌫"],
	"space": [KEY_SPACE, "␣"],
	"left": [KEY_LEFT, "←"],
	"right": [KEY_RIGHT, "→"],
	"up": [KEY_UP, "↑"],
	"down": [KEY_DOWN, "↓"],
}


func _key(code: Key, unicode: int, modifiers: Dictionary, label: String) -> void:
	overlay.key(label)
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode if down else 0
		event.pressed = down
		event.meta_pressed = modifiers.get("cmd", false)
		event.ctrl_pressed = modifiers.get("ctrl", false)
		event.alt_pressed = modifiers.get("alt", false)
		event.shift_pressed = modifiers.get("shift", false)
		Input.parse_input_event(event)
		await wait(0.05)


## Enters text in one burst, as if pasted, through the keyboard: effects that
## follow typing still see every key. {enter}, {tab}, {escape} ... name keys.
func type(text: String) -> void:
	if OS.get_name() == "Windows" and host.is_terminal_pane(host.pane_focus):
		var id := int(host.pane_focus.substr(1))
		if host.sessions.has(id):
			var terminal: Node = host.sessions[id].term
			var deadline := Time.get_ticks_msec() + 15000
			# Cwd requires shell integration and is absent in direct Neovim
			# sessions. Wait for actual terminal output, also without integration.
			while str(terminal.get_text(false).get("text", "")).strip_edges().is_empty() and Time.get_ticks_msec() < deadline:
				await process_frame
			check(not str(terminal.get_text(false).get("text", "")).strip_edges().is_empty(), "Windows terminal produces output before typing")
	# Native PowerShell equivalents for the shell commands used by these fixtures.
	if OS.get_name() == "Windows" and text.ends_with("{enter}"):
		text = text.replace('"$GRAFFITTY_BIN"', '& $env:GRAFFITTY_BIN').replace(' > /dev/null', ' > $null').replace('$$', '$PID')
		if text.begins_with("printf '") and text.ends_with("'{enter}"):
			var value := text.substr(8, text.length() - 16).replace("\\033", "\u001b").replace("\\007", "\u0007").replace("\\n", "\n").replace("%%", "%")
			text = "[Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))){enter}" % Marshalls.utf8_to_base64(value)
	overlay.key(
		text
		.replace("{enter}", " ↵")
		.replace("{tab}", " ⇥")
		.replace("{escape}", " esc")
		.replace("{backspace}", "⌫")
	)
	var i := 0
	while i < text.length():
		var ch := text[i]
		if ch == "{" and text.find("}", i) > i:
			var name := text.substr(i + 1, text.find("}", i) - i - 1)
			if NAMED.has(name):
				_send_key(NAMED[name][0], 0, { })
				i = text.find("}", i) + 1
			else:
				_send_key(KEY_NONE, ch.unicode_at(0), { })
				i += 1
		else:
			var code: Key = (
				OS.find_keycode_from_string(ch.to_upper())
				if (ch.to_upper() != ch.to_lower() or ch.is_valid_int())
				else KEY_NONE
			)
			_send_key(code, ch.unicode_at(0), { "shift": ch != ch.to_lower() })
			i += 1
	await wait(0.6)


func _send_key(code: Key, unicode: int, modifiers: Dictionary) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode if down else 0
		event.pressed = down
		event.meta_pressed = modifiers.get("cmd", false)
		event.ctrl_pressed = modifiers.get("ctrl", false)
		event.alt_pressed = modifiers.get("alt", false)
		event.shift_pressed = modifiers.get("shift", false)
		Input.parse_input_event(event)


## A shortcut such as "cmd+t" or "ctrl+shift+tab".
func keys(combo: String) -> void:
	if OS.get_name() in ["Windows", "Linux"]:
		# Replays describe the application's macOS Command shortcuts. Windows and
		# Linux use Ctrl+Shift for menu actions. Prefix replays use Ctrl+A directly.
		if combo in ["cmd+z", "cmd+shift+z"]:
			combo = combo.replace("cmd+", "ctrl+")
		else:
			combo = combo.replace("cmd+", "ctrl+shift+")
	var parts := Array(combo.to_lower().split("+"))
	var modifiers := { }
	var label := ""
	for part in parts.slice(0, parts.size() - 1):
		modifiers[part] = true
		label += { "cmd": "⌘", "ctrl": "⌃", "alt": "⌥", "shift": "⇧" }.get(part, part)
	var last: String = parts[-1]
	var code: Key = (
		NAMED[last][0]
		if NAMED.has(last)
		else OS.find_keycode_from_string(last.to_upper())
	)
	label += NAMED[last][1] if NAMED.has(last) else last.to_upper()
	await _key(code, 0, modifiers, label)
	await wait(0.3)

# --- finding things on screen -------------------------------------------------


## A point inside a control, in window pixels: fraction (0.5, 0.5) is its
## middle.
##
## Windows live on the workspace canvas, which the camera shows on the world's
## sheet, so their points are carried through the camera to the screen.
##
## Moves the pointer onto a pane's title row, where desktop actions appear.
func hover_header(key: String) -> Control:
	var view: Control = host.workspace_view
	var header: Control = view.panes[key].header
	await point_at(view.window_point(header.get_global_transform() * Vector2(header.size.x * 0.6, header.size.y * 0.5)))
	for i in 90:
		if header.hovered: break
		await process_frame
	check(header.hovered, "Pointer hovers the pane header of " + key)
	return header


## Window point of a pane header action (`filetree`, `chromium`,
## `split_right`, `split_down`, `close`).
##
## The header is a mod whose actions appear on hover, so the pointer first
## moves onto the header, then the point is measured.
func on_header(key: String, part: String) -> Vector2:
	var view: Control = host.workspace_view
	var header: Control = view.panes[key].header
	if not header.has_part(part):
		await point_at(view.window_point(header.get_global_transform() * Vector2(header.size.x * 0.6, header.size.y * 0.5)))
		for i in 90:
			if header.has_part(part): break
			await process_frame
		check(header.has_part(part), "Pane header shows " + part + " on hover")
	return view.window_point(header.get_global_transform() * header.part_rect(part).get_center())


func on(control: Control, fraction := Vector2(0.5, 0.5)) -> Vector2:
	var view: Control = host.workspace_view
	if control.get_viewport() == view.canvas:
		# Layout pixels on the canvas; its own transform only picks what to raster.
		return view.window_point(control.get_global_transform() * (control.size * fraction))
	return control.get_global_transform_with_canvas() * (control.size * fraction)


## A point of the tab content below the bar: fraction (0.5, 0.5) is its middle.
func content(fraction := Vector2(0.5, 0.5)) -> Vector2:
	var view: Control = host.workspace_view
	var area := Rect2(
		view.get_global_rect().position + Vector2(0, view.BAR_HEIGHT),
		view.size - Vector2(0, view.BAR_HEIGHT),
	)
	return area.position + area.size * fraction


func tab_strip() -> Control:
	return host.workspace_view.tab_bar.tabs


func tab_button(index: int) -> Control:
	return tab_strip().buttons[int(host.get_tabs()[index].id)]


## Where a person grabs a tab: beside its close button, which on a narrow tab
## covers the middle while the tab is selected and hovered.
func tab_grip(index: int) -> Vector2:
	var button := tab_button(index)
	var close: Control = button.get_node_or_null("Close")
	var left := close.position.x if close != null else button.size.x * 0.5
	return on(button, Vector2(clampf(left * 0.5 / maxf(button.size.x, 1.0), 0.05, 0.3), 0.5))


## Tab titles from left to right, as the bar shows them.
func titles() -> Array[String]:
	var result: Array[String] = []
	for tab in host.get_tabs():
		result.append(String(tab.title))
	return result


func tab_index(title: String) -> int:
	var all := titles()
	for i in all.size():
		if all[i] == title or all[i].begins_with(title + " ·"):
			return i
	return -1


func selected_title() -> String:
	for tab in host.get_tabs():
		if tab.active:
			return String(tab.title)
	return ""


## The terminal a title belongs to.
func terminal_id(title: String) -> int:
	for id in host.sessions:
		var model: Node = host.session_model(id)
		if model != null and model.title == title:
			return id
	return -1


func shell_pid(title: String) -> int:
	var id := terminal_id(title)
	return host.sessions[id].term.get_shell_pid() if id >= 0 else -1


## What a terminal window shows, a line per row, read from its cells.
func screen_text(title: String) -> String:
	var id := terminal_id(title)
	return terminal_text(id) if id >= 0 else ""


## What terminal `id` shows, a line per row, read from its cells.
func terminal_text(id: int) -> String:
	var lines := { }
	for glyph in host.sessions[id].term.cell_glyphs():
		var line: PackedStringArray = lines.get(glyph.row, PackedStringArray())
		while line.size() <= glyph.col:
			line.append(" ")
		line[glyph.col] = char(glyph.cp)
		lines[glyph.row] = line
	var rows := lines.keys()
	rows.sort()
	return "\n".join(
		rows.map(
			func(row):
				return "".join(lines[row]),
		)
	)


## A terminal window's pane on the canvas, and its drag handle.
func window(title: String) -> Control:
	return host.workspace_view.panes.get("%%%d" % terminal_id(title))


func handle(title: String) -> Control:
	return window(title).handle


## Opens tabs until there are `count`, without ceremony: setup, not the test.
func open_tabs(count: int) -> void:
	while host.get_tabs().size() < count:
		var previous: int = host.get_tabs().size()
		host.create_session()
		var deadline := Time.get_ticks_msec() + 10000
		while host.get_tabs().size() == previous and Time.get_ticks_msec() < deadline: await process_frame
		if not check(host.get_tabs().size() > previous, "Shared owner creates the requested tab"):
			return
		await owner_at_rest()


var world_sessions: Array[String] = []

## World locations belong to owner sessions. Setup uses the real owner, and
## switches use the same action as the Sessions menu.
func open_world_sessions(count: int) -> void:
	var peer: Node = preload("res://scenes/session/LiveSessionMenu.gd").transport(host)
	if world_sessions.is_empty(): world_sessions.append(peer.workspace)
	while world_sessions.size() < count:
		var result: Dictionary = await peer.request_action("session_new", {})
		if not check(result.get("type") != "error", "Owner creates a world session"): return
		await owner_at_rest()
		await camera_at_rest()
		world_sessions.append(peer.workspace)
	await select_world_session(0)
	await camera_at_rest()

func select_world_session(index: int) -> void:
	var peer: Node = preload("res://scenes/session/LiveSessionMenu.gd").transport(host)
	await preload("res://scenes/session/LiveSessionMenu.gd").switch_to(host, peer, world_sessions[index])
	await owner_at_rest()
	var deadline := Time.get_ticks_msec() + 10000
	while (host.session_switch_in_progress or host.active_terminal() == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not host.session_switch_in_progress and host.active_terminal() != null, "Destination session installs its live terminal")
	check(peer.workspace == world_sessions[index], "Sessions action selects destination %d" % (index + 1))


## Clicks a tab and waits until its terminal takes the keyboard: a tab switch
## animates, and keys typed before it lands would go nowhere.
func select_tab(index: int) -> void:
	var id := int(host.get_tabs()[index].id)
	# A person waits for sliding tabs to stop before picking one.
	for i in 120:
		if not tab_strip()._settling:
			break
		await process_frame
	await click(tab_grip(index))
	for i in 240:
		var pair: Dictionary = host.sessions.get(host.active_session_id, { })
		if (
			host.workspace_layout.active == id and not pair.is_empty()
			and not pair.vp.gui_disable_input and host.world.term == pair.term
		):
			break
		await process_frame
	await hold(0.1)
	await wait(0.3)


## Names a tab's window as `gft pane rename` run in it does, so
## its header and, automatically, its tab read the name; notes its shell.
var shells := { }


func label_tab(index: int, title: String) -> void:
	var id := int(host.get_tabs()[index].id)
	await app.agent_api.dispatch(id, "window.set_title", { "title": title })
	shells[title] = shell_pid(title)


func labelled_tabs(names: Array) -> void:
	await say("Setup: %d tabs named %s" % [names.size(), ", ".join(names)])
	await open_tabs(names.size())
	for i in names.size():
		await label_tab(i, names[i])
	# Clicking the already-selected tab arms the workspace prefix. Setup should
	# leave ordinary terminal input ready, including the single-tab case.
	if host.workspace_layout.active != int(host.get_tabs()[0].id):
		await select_tab(0)
	await camera_at_rest()


## Typing zooms the camera toward the cursor; a person waits for it to ease
## back before reaching for a window header it may have pushed off screen.
##
## At rest the picture holds still: the canvas corners move under a fifth of a
## pixel a second. (A pinch sets the zoom at once and leaves the pan easing.)
func owner_at_rest() -> void:
	if not host.session_backend.has_method("work_pending"): return
	var deadline := Time.get_ticks_msec() + 10000
	var quiet := 0
	while quiet < 3 and Time.get_ticks_msec() < deadline:
		await process_frame
		quiet = 0 if host.session_backend.work_pending() else quiet + 1
	if quiet < 3:
		print("OWNER_PENDING ", JSON.stringify({"edit": host.session_backend.pending_edit, "tab_edit": host.session_backend.pending_tab_edit, "queued": host.session_backend.queued_edits, "operations": host.session_backend.pending_operations, "revision": host.session_backend.connection.topology.get("workspace_revision", -1)}))
	check(quiet >= 3, "Shared workspace edits are acknowledged before reading layout")

func camera_at_rest(seconds := 8.0) -> void:
	await owner_at_rest()
	var world: Node = host.world
	var view: Control = host.workspace_view
	var until: float = overlay.clock + seconds
	var still := 0
	var last := PackedVector2Array()
	var last_at := 0.0
	while overlay.clock < until and still < 3:
		await process_frame
		var corners := PackedVector2Array(
			[view.window_point(Vector2.ZERO), view.window_point(view.canvas_size())]
		)
		var speed := INF
		if not last.is_empty() and overlay.clock > last_at:
			speed = maxf(corners[0].distance_to(last[0]), corners[1].distance_to(last[1])) / (
				overlay.clock - last_at
			)
		still = still + 1 if world.fx_typing <= 0.01 and landed() and world.tab_fx_t < 0.0 and speed < 0.2 else 0
		last = corners
		last_at = overlay.clock
	await wait(0.3)


## Layout references must be captured after collision responses settle, too.
## Camera rest alone says nothing about floating panes still moving underneath.
func panes_at_rest(seconds := 20.0) -> void:
	await camera_at_rest(seconds)
	var view: Control = host.workspace_view
	var until: float = overlay.clock + seconds
	var stable := 0
	while overlay.clock < until and stable < 3:
		await process_frame
		stable = stable + 1 if not view.physics_enabled() or view.pane_physics.sleeping else 0
	check(stable >= 3, "Floating panes settle before capturing the layout")


## Every labelled shell is still the process it was.
func check_same_shells() -> void:
	var changed: Array[String] = []
	for title in shells:
		if shell_pid(title) != shells[title]:
			changed.append(title)
	check(
		changed.is_empty(),
		"Every shell is the same process as before"
		+ ("" if changed.is_empty() else ", except " + ", ".join(changed)),
	)


## Drags one tab onto another, holds until it opens, and drops into it.
func merge_tab(source: String, target: String) -> void:
	await point_at(tab_grip(tab_index(source)))
	await press()
	await point_at(on(tab_button(tab_index(target))), 1.0)
	await hold(0.9)
	await point_at(content(Vector2(0.5, 0.45)), 0.8)
	await wait(0.3)
	await release()
	await wait(0.6)
	await owner_at_rest()

# --- camera -------------------------------------------------------------------


## A case's effect preset, loaded into the running world as --config would.
func use_config(path: String) -> void:
	host.world.fx_cfg.load_config(path)
	host.world._fx_apply_scene()


## Records the displayed camera every frame while the replay goes on acting.
var _watching := false
var _watch_generation := 0
var _watched: Array[Dictionary] = []


func start_watching_camera() -> void:
	_watch_generation += 1
	_watched = []
	_watching = true
	_watch_loop(_watch_generation)


func _watch_loop(generation: int) -> void:
	while _watching and generation == _watch_generation:
		await process_frame
		# A new capture may start before this coroutine resumes from the old
		# one. Never let that old waiter append duplicate frames to the new run.
		if not _watching or generation != _watch_generation:
			return
		var world: Node = host.world
		_watched.append(
			{
				"eye": world.proj_eye,
				"forward": world.proj_forward,
				"lens": world.proj_rect.z,
				"at": overlay.clock,
				"zoom": world.fx_camera.zoom,
				"depth": (world.uv_origin - world.proj_eye).dot(world.proj_forward),
			}
		)


func stop_watching_camera() -> Array[Dictionary]:
	_watching = false
	return _watched


func landed() -> bool:
	return not host.world.camera_motion.moving and host.world.fly_dur <= 0.0


func wait_landed(seconds := 6.0) -> void:
	var until: float = overlay.clock + seconds
	while not landed() and overlay.clock < until:
		await process_frame
	await wait(0.4)


## The app sleeps its world while its window lacks focus, and the OS will not
## give a replay's window focus while someone works elsewhere: --no-focus-skip.
func _stay_awake() -> void:
	host.world.background_skip = false
	host.world._set_world_awake(true)


## Opens Bistro the way the View menu does; the native menu bar is outside
## the window, so the replay shows the menu path and chooses the world itself.
func open_bistro() -> bool:
	await say("Choose View > World > Bistro")
	overlay.key("View › World › Bistro")
	var opened: bool = host.switch_world("bistro")
	check(opened, "Bistro opens")
	_stay_awake()
	for i in 300:
		if landed() and host.world.surfaces.size() > 1:
			break
		await process_frame
	await hold(1.0)
	return opened


## The displayed camera, frame by frame, for a while.
func watch_camera(seconds: float) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	var until: float = overlay.clock + seconds
	while overlay.clock < until:
		await process_frame
		var world: Node = host.world
		frames.append(
			{
				"eye": world.proj_eye,
				"forward": world.proj_forward,
				"lens": world.proj_rect.z,
				"at": overlay.clock,
				"depth": (world.uv_origin - world.proj_eye).dot(world.proj_forward),
			}
		)
	return frames


## A jump cut is a frame in which the camera moves, turns or changes lens far
## faster than in the frames around it: an isolated spike, big enough to see.
##
## A motion that starts briskly from rest keeps going the next frame, so it is
## not one; nor is a long frame, which only covers more of the same motion.
func check_no_jump_cut(frames: Array[Dictionary], label: String) -> void:
	var path := 0.0
	for i in range(1, frames.size()):
		path += frames[i].eye.distance_to(frames[i - 1].eye)
	var worst := ""
	for i in range(4, frames.size() - 2):
		var change := _camera_change(frames[i - 1], frames[i])
		var rate := change / _frame_time(frames, i)
		var around := Vector3.ZERO
		for j in range(i - 3, i + 3):
			if j != i:
				around = around.max(_camera_change(frames[j - 1], frames[j]) / _frame_time(frames, j))
		# Too small to see is no cut: under half a percent of the sheet's distance.
		var visible := absf(frames[i].get("depth", 0.0)) * 0.005
		if (
			(change.x > maxf(path * 0.01, visible) and rate.x > around.x * 2.5)
			or (change.y > 0.3 and rate.y > around.y * 2.5)
			or (change.z > 0.005 and rate.z > around.z * 2.5)
		):
			var usual := around * _frame_time(frames, i)
			worst = " - at %.2f s the camera moves %.2f against %.2f around it, turns %.2f° against %.2f°" % [
				frames[i].at - frames[0].at,
				change.x,
				usual.x,
				change.y,
				usual.y,
			]
			break
	check(worst.is_empty(), "%s: no jump cut%s" % [label, worst])


## A landing is one deceleration: once the camera has slowed below 40% of its
## top speed, it keeps slowing.
##
## Speeding up again there, say for a last push of zoom, is a second stage.
## Easing through a waypoint mid-route is not.
func check_one_motion(frames: Array[Dictionary], label: String) -> void:
	var speeds: Array[float] = []
	for i in range(1, frames.size()):
		speeds.append(frames[i].eye.distance_to(frames[i - 1].eye) / _frame_time(frames, i))
	if speeds.is_empty():
		check(false, "%s: the camera moved" % label)
		return
	var fastest: float = speeds.max()
	var slowest := INF
	var again := ""
	for i in range(speeds.find(fastest), speeds.size()):
		if slowest == INF and speeds[i] >= fastest * 0.4:
			continue
		slowest = minf(slowest, speeds[i])
		if speeds[i] > slowest * 1.5 and speeds[i] > fastest * 0.1:
			again = " - it speeds up again at %.2f s" % (frames[i + 1].at - frames[0].at)
			break
	check(again.is_empty(), "%s: lands in one motion, no last push%s" % [label, again])


## How long frame `i` lasted, in the app's own time: a slow frame covers more.
func _frame_time(frames: Array[Dictionary], i: int) -> float:
	return maxf(frames[i].at - frames[i - 1].at, 1e-4)


func _camera_change(a: Dictionary, b: Dictionary) -> Vector3:
	return Vector3(
		b.eye.distance_to(a.eye),
		rad_to_deg(b.forward.angle_to(a.forward)),
		absf(b.lens / maxf(a.lens, 1e-6) - 1.0),
	)

# --- what is on screen --------------------------------------------------------


## The window as rendered, without the replay's own pointer and captions.
func screen_image() -> Image:
	overlay.visible = false
	await process_frame
	if Background.enabled():
		# The background scheduler draws once the app and canvas have updated.
		# An extra force_draw here would also append an extra movie frame.
		await RenderingServer.frame_post_draw
	else:
		# An idle visible window need not issue frame_post_draw by itself.
		RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	overlay.visible = true
	return image


## The frames around `action`: the one before it, then the first and the last
## `keep` of those rendered after it until `done` holds. `action` must not
## wait, so no frame is missed.
func frames_during(action: Callable, done: Callable, keep := 2, limit := 600) -> Array[Image]:
	# Match screen_image(): an idle, unobscured frame need not draw itself.
	overlay.visible = false
	await process_frame
	if Background.enabled():
		await RenderingServer.frame_post_draw
	else:
		RenderingServer.force_draw(false)
	var frames: Array[Image] = [root.get_texture().get_image()]
	action.call()
	for i in limit:
		await RenderingServer.frame_post_draw
		if frames.size() > 2 * keep:
			frames.remove_at(keep + 1)
		frames.append(root.get_texture().get_image())
		if done.call():
			break
	overlay.visible = true
	return frames


## How crisp the edges in a window-pixel rectangle are: the steepness of the
## steepest tenth of luminance edges, in luminance per rendered pixel.
##
## Crisp text steps from background to glyph within a pixel or two; a
## magnified or defocused texture spreads the same step over many.
func edge_steepness(image: Image, rect: Rect2) -> float:
	var scale := Vector2(image.get_size()) / root.get_visible_rect().size
	var area := Rect2i(Rect2(rect.position * scale, rect.size * scale)).intersection(
		Rect2i(Vector2i.ZERO, image.get_size() - Vector2i.ONE)
	)
	var steepness: Array[float] = []
	for y in range(area.position.y + 1, area.end.y - 1):
		for x in range(area.position.x + 1, area.end.x - 1):
			var dx := image.get_pixel(x + 1, y).get_luminance() - image \
					.get_pixel(x - 1, y) \
					.get_luminance()
			var dy := image.get_pixel(x, y + 1).get_luminance() - image \
					.get_pixel(x, y - 1) \
					.get_luminance()
			var gradient := Vector2(dx, dy).length() * 0.5
			if gradient > 0.02:
				steepness.append(gradient)
	if steepness.size() < 20:
		return 0.0
	steepness.sort()
	return steepness[int(steepness.size() * 0.9)]


## The middle of the part of a window's control that is on screen, or INF.
func visible_point(control: Control) -> Vector2:
	var corners: Array[Vector2] = [
		on(control, Vector2.ZERO),
		on(control, Vector2.ONE),
		on(control, Vector2(0, 1)),
		on(control, Vector2(1, 0)),
	]
	var box := Rect2(corners[0], Vector2.ZERO)
	for corner in corners:
		box = box.expand(corner)
	var shown := box.intersection(
		Rect2(content(Vector2.ZERO), content(Vector2.ONE) - content(Vector2.ZERO)).grow(-12)
	)
	return shown.get_center() if shown.has_area() else Vector2.INF


## Luminance of a window-pixel rectangle, for comparing frames.
func luma(image: Image, rect: Rect2) -> Dictionary:
	var scale := Vector2(image.get_size()) / root.get_visible_rect().size
	var area := Rect2i(Rect2(rect.position * scale, rect.size * scale)).intersection(
		Rect2i(Vector2i.ZERO, image.get_size())
	)
	var values := PackedFloat32Array()
	values.resize(area.size.x * area.size.y)
	for y in area.size.y:
		for x in area.size.x:
			values[y * area.size.x + x] = image.get_pixel(area.position.x + x, area.position.y + y).get_luminance()
	return { "w": area.size.x, "h": area.size.y, "v": values }


## How far the picture in one frame moved to give another, in rendered pixels:
## the shift within `radius` that makes them most alike, and how unlike they
## still are there (mean luminance difference).
func best_shift(before: Dictionary, after: Dictionary, radius := 3) -> Dictionary:
	var best := { "shift": Vector2i.ZERO, "difference": INF }
	var w: int = mini(before.w, after.w)
	var h: int = mini(before.h, after.h)
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var total := 0.0
			var count := 0
			for y in range(radius, h - radius, 2):
				for x in range(radius, w - radius, 2):
					total += absf(before.v[y * before.w + x] - after.v[(y + dy) * after.w + x + dx])
					count += 1
			var difference := total / maxf(count, 1)
			if difference < best.difference - 1e-6:
				best = { "shift": Vector2i(dx, dy), "difference": difference }
	return best

# --- checks -------------------------------------------------------------------


func check(ok: bool, message: String) -> bool:
	print("[replay] ", "PASS " if ok else "FAIL ", message)
	overlay.toast(ok, message)
	if not ok:
		failures.append(message)
	return ok


func finish() -> void:
	await wait(1.5)
	failures.append_array(diagnostic_guard.failures)
	for error in _errors.errors:
		failures.append("Script error: " + error)
		print("[replay] FAIL Script error: ", error)
	var name := String(get_script().resource_path.get_file().get_basename()).to_upper().replace(
		"-",
		"_",
	)
	print("%s_REPLAY_%s" % [name, "PASS" if failures.is_empty() else "FAIL: " + str(failures)])
	quit(0 if failures.is_empty() else 1)
