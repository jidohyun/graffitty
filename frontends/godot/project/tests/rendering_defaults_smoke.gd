extends SceneTree
## Run with the actual active renderer. --expect-software asserts CPU/software
## defaults; without it, assert normal hardware/headless defaults. This flag
## changes only the expectation, never the detected renderer or configuration.
class BackdropHost extends Node:
	var world: Node
	var world_viewport := SubViewport.new()


func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var software := "--expect-software" in OS.get_cmdline_user_args()
	var args := PackedStringArray(["--no-config"])
	var config := preload("res://config/UserConfig.gd")
	var world: String = config.world_path(args)
	var profiles := preload("res://scenes/EffectProfiles.gd").new(args)
	var correct := world == ("flat-2d" if software else "") and profiles.selected == ("off" if software else "world")
	var transparent := preload("res://graffitty/window_transparency.gd").available()
	var host := BackdropHost.new()
	root.add_child(host)
	host.add_child(host.world_viewport)
	var blur := preload("res://scenes/DesktopBlur.gd").new()
	host.add_child(blur)
	blur.host = host
	blur.settings = config.window_config(args)
	blur.settings.background_blur = false
	host.world_viewport.transparent_bg = true
	blur.apply()
	correct = correct and root.transparent == transparent and root.transparent_bg == transparent and host.world_viewport.transparent_bg
	host.world_viewport.transparent_bg = false
	blur.apply()
	correct = correct and not root.transparent and not root.transparent_bg
	host.free()
	var terminal: RefCounted = config.terminal_config(args)
	correct = correct and terminal.background.color == Color("282c34") and is_equal_approx(terminal.background.alpha, 0.85)
	var fixture_nodes := Node.get_orphan_node_ids()
	var flat_3d := preload("res://scenes/FlatTerminalSpaceWorld.gd").new()
	flat_3d.terminal_config = terminal.copy()
	flat_3d._load_background_config()
	var backdrop: Color = flat_3d.bg_color
	correct = correct and backdrop == Color("282c34" if transparent else "3b4452")
	correct = correct and flat_3d.terminal_config.background.color == Color("282c34") and is_equal_approx(flat_3d.terminal_config.background.alpha, 0.85)
	flat_3d.terminal_config.background.alpha = 0.35
	flat_3d._load_background_config()
	correct = correct and flat_3d.bg_color == backdrop and is_equal_approx(flat_3d.terminal_config.background.alpha, 0.35)
	flat_3d.free()
	var flat_2d := preload("res://scenes/Flat2DWorld.gd").new()
	flat_2d.terminal_config = terminal.copy()
	flat_2d._load_background_config()
	correct = correct and flat_2d.bg_color == backdrop
	correct = correct and flat_2d.terminal_config.background.color == Color("282c34") and is_equal_approx(flat_2d.terminal_config.background.alpha, 0.85)
	flat_2d.free()
	# These worlds own child fixtures that are parented only by _ready().
	for id in Node.get_orphan_node_ids():
		if id in fixture_nodes or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	# Mobile project overrides select the opaque default independently of GPU.
	for platform in ["android", "ios"]:
		correct = correct and not bool(ProjectSettings.get_setting_with_override_and_custom_features("display/window/per_pixel_transparency/allowed", PackedStringArray([platform])))
	config.apply_terminal(terminal, {"background": {"color": "#123456"}})
	correct = correct and terminal.background.color == Color("123456")
	print(JSON.stringify({"adapter": RenderingServer.get_video_adapter_name(),
		"type": RenderingServer.get_video_adapter_type(), "display": DisplayServer.get_name(),
		"world": world, "effects": profiles.selected, "window_transparency": transparent,
		"terminal_background": config.terminal_config(args).background.color.to_html(false),
		"flat_3d_background": backdrop.to_html(false)}))
	print(("PASS" if correct else "FAIL") + " active renderer selects startup defaults")
	# Let the native background guard observe startup and the hidden window.
	await create_timer(0.3).timeout
	quit(0 if correct else 1)
