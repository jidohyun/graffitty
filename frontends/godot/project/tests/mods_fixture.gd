extends SceneTree
## Shared fixture for mod smoke tests: a TerminalApplication stand-in
## with a real mod service, a dock space, and a host with a workspace view.
## No servers, saved connections, audio or private state.
const Service := preload("res://scenes/mods/ModService.gd")
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")

class View extends Control:
	var tab_bar := Control.new()
	var toolbar: Control
	var insets := Vector4.ZERO
	func _ready() -> void:
		add_child(tab_bar)
		tab_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		tab_bar.offset_bottom = 34
	func set_dock_insets(value: Vector4) -> void: insets = value

class Layout extends RefCounted:
	var active := 0
	var tabs: Array = []

class Profiles extends RefCounted:
	var selected := "world"
	func names() -> Array[String]: return ["world", "off", "mild", "exaggerated"]
	func label(name: String) -> String: return name.capitalize()
	func is_builtin(_name: String) -> bool: return true
	func has(name: String) -> bool: return name in names()

class World extends Node:
	var fx_cfg := {}

class Host extends Node:
	signal ui_changed
	var tiling_config := {"gap": 8.0}
	var layout_root := Control.new()
	var workspace_view := View.new()
	var workspace_layout := Layout.new()
	var effect_profiles := Profiles.new()
	var pane_focus := "%1"
	var active_session_id := 1
	var application: Node
	var world: Node = World.new()
	var server_chooser := Callable()
	var sample: Node
	var focused_key := ""
	var profile_set := ""
	var effect_switches: Dictionary = {}
	var prefix_commands := PrefixStub.new()
	func _ready() -> void:
		prefix_commands.host = self
		add_child(layout_root)
		layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layout_root.add_child(workspace_view)
		workspace_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	func is_chromium_pane(_key: String) -> bool: return false
	func is_terminal_pane(_key: String) -> bool: return true
	func pane_title(key: String) -> String: return "Pane " + key
	func resource_monitor_for(_id: int) -> Node: return sample
	func focus_pane(key: String) -> void: focused_key = key
	func active_terminal() -> Node: return null
	func set_effects_profile(name: String) -> void:
		profile_set = name
		effect_profiles.selected = name
		application.mods.publish_window(self)
	func toggle_effect(effect: String) -> void:
		if effect_switches.has(effect): effect_switches.erase(effect)
		else: effect_switches[effect] = Callable()
		application.mods.publish_window(self)

## The workspace prefix as the status line sees it: a key, an armed flag, a toggle.
class PrefixStub extends RefCounted:
	var host: Node
	var active := false
	var settings := {"key": KEY_A | KEY_MASK_CTRL}
	func toggle() -> void:
		active = not active
		host.application.mods.publish_prefix(host)

class Sample extends Node:
	signal snapshot_changed(data: Dictionary)
	var cpu := 12.0
	var memory := 1048576
	func snapshot() -> Dictionary:
		return {"status": "running", "cpu_valid": true, "cpu_percent": cpu, "memory_current": memory,
			"memory_peak_observed": 2097152, "process_count": 2, "root_pid": 123}

class AgentsModel extends Node:
	signal changed
	var rows: Array = []
	var trees: Dictionary = {}
	var focused := ""
	var pinned := {}
	func focus(id: String) -> void: focused = id
	func pin(id: String, value: bool) -> void: pinned[id] = value

class Space extends "res://scenes/ListDockSpace.gd":
	var test_hosts: Array = []
	var reflows := 0
	func _window_hosts() -> Array: return test_hosts
	func reflow() -> void:
		reflows += 1
		super()

class ObservedService extends Service:
	var session_publications := 0
	func _publish_sessions() -> void:
		session_publications += 1
		super()

class App extends Node:
	var scripted_pointer := true
	var hosts: Array = []
	var agents := AgentsModel.new()
	var mods: Node
	func session_hosts() -> Array: return hosts.duplicate()
	func present_desktop_client(_client: Node) -> void: pass
	func opens_windows() -> bool: return not OS.has_feature("mobile")
	func _init() -> void:
		name = "TerminalApplication"
		add_child(agents)
		mods = ObservedService.new()
		mods.application = self
		add_child(mods)

var failures: Array[String] = []
var app: App
var host: Host
var space: Space

func check(ok: bool, message: String) -> bool:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)
	return ok

func settle(frames := 3) -> void:
	for i in frames: await process_frame

func _initialize() -> void:
	var directory := OS.get_cache_dir().path_join("gft-mods-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	TranslationServer.set_locale("en_US")
	run.call_deferred()

func setup(mobile := false) -> void:
	# The Localization autoload applied the device language after _initialize;
	# assertions use English source text.
	TranslationServer.set_locale("en_US")
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1" if mobile else "0")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(390, 780) if mobile else Vector2i(1280, 800)
	root.gui_embed_subwindows = mobile
	app = App.new()
	app.name = "TerminalApplication"
	root.add_child(app)
	host = Host.new()
	host.application = app
	host.sample = Sample.new()
	host.add_child(host.sample)
	root.add_child(host)
	app.hosts = [host]
	space = Space.new()
	space.state_path = OS.get_cache_dir().path_join("gft-mods-dock-%d.json" % OS.get_process_id())
	DirAccess.remove_absolute(space.state_path)
	root.add_child(space)
	space.test_hosts = [host]
	root.set_meta(&"list_dock_space", space)
	check(app.mods.available, "Mod host is available")

func finish(tag: String) -> void:
	DirAccess.remove_absolute(space.state_path)
	print("%s_%s" % [tag, "PASS" if failures.is_empty() else "FAIL"])
	quit(0 if failures.is_empty() else 1)

## Runs mod requests now, the way the service does once per frame.
func pump() -> void:
	for request in app.mods.host.take_requests(): app.mods._handle(request)

func texts(window: Window) -> PackedStringArray:
	return window.texts()

func has_text(window: Window, needle: String) -> bool:
	for text in texts(window):
		if needle in text: return true
	return false

func run() -> void:
	pass
