extends RefCounted
## Periodic render-memory report for field diagnosis of GPU memory on phones.
##
## One line of engine counters plus every live SubViewport with its size and
## format, printed to the engine log (logcat on Android). Enabled on mobile,
## or anywhere with `--render-stats`.
##
## Prints are plain text with no paths.
const INTERVAL_MSEC := 30000
const FrameProfile := preload("res://graffitty/frame_profile.gd")
static var _next_msec := 0
static var _enabled := -1
static var _hooks_connected := false
static var _last_frames_drawn := -1


static func enabled() -> bool:
	if _enabled < 0:
		_enabled = 1 if OS.has_feature("mobile") or "--render-stats" in OS.get_cmdline_user_args() else 0
	return _enabled == 1


static func tick(tree: SceneTree) -> void:
	if not enabled() or tree == null: return
	_connect_frame_hooks(tree)
	FrameProfile.frame()
	var now := Time.get_ticks_msec()
	if now < _next_msec: return
	_next_msec = now + INTERVAL_MSEC
	var frames_drawn := Engine.get_frames_drawn()
	var drawn := 0 if _last_frames_drawn < 0 else frames_drawn - _last_frames_drawn
	_last_frames_drawn = frames_drawn
	print(report(tree))
	print(FrameProfile.take(drawn))


static func _connect_frame_hooks(tree: SceneTree) -> void:
	if _hooks_connected: return
	tree.process_frame.connect(FrameProfile.process_frame_started)
	RenderingServer.frame_post_draw.connect(FrameProfile.frame_post_draw)
	_hooks_connected = true


static func report(tree: SceneTree) -> String:
	var mib := 1048576.0
	var lines := PackedStringArray()
	lines.append("[render-stats] video=%.0fMiB textures=%.0fMiB buffers=%.0fMiB nodes=%d orphans=%d draw_calls=%d objects=%d process=%.1fms static=%.0fMiB" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / mib,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / mib,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / mib,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / mib,
	])
	var root: Window = tree.root
	lines.append("[render-stats]  root %dx%d hdr=%s 3d=%s" % [root.size.x, root.size.y, root.use_hdr_2d, not root.disable_3d])
	var total_pixels := 0
	var rs := RenderingServer
	rs.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	lines[1] += " render cpu=%.1fms gpu=%.1fms" % [rs.viewport_get_measured_render_time_cpu(root.get_viewport_rid()), rs.viewport_get_measured_render_time_gpu(root.get_viewport_rid())]
	for viewport in _viewports(root):
		var bytes_per_pixel: int = 8 if viewport.use_hdr_2d else 4
		var pixels: int = viewport.size.x * viewport.size.y
		if pixels <= 4: continue
		total_pixels += pixels
		var rid := viewport.get_viewport_rid()
		rs.viewport_set_measure_render_time(rid, true)
		lines.append("[render-stats]  %s %dx%d hdr=%s 3d=%s mode=%d ~%.1fMiB render cpu=%.1fms gpu=%.1fms" % [
			_label(viewport), viewport.size.x, viewport.size.y, viewport.use_hdr_2d, not viewport.disable_3d,
			viewport.render_target_update_mode, pixels * bytes_per_pixel / mib,
			rs.viewport_get_measured_render_time_cpu(rid), rs.viewport_get_measured_render_time_gpu(rid)])
	lines.append("[render-stats]  subviewport pixels total=%d" % total_pixels)
	return "\n".join(lines)


static func _viewports(node: Node) -> Array[SubViewport]:
	var result: Array[SubViewport] = []
	if node is SubViewport: result.append(node)
	for child in node.get_children(true): result.append_array(_viewports(child))
	return result


static func _label(viewport: SubViewport) -> String:
	var parent: Node = viewport.get_parent()
	var owner_name: String = str(parent.name) if parent != null else "?"
	var kind: String = "pane" if viewport.has_meta("terminal_render_node") else "view"
	return "%s:%s/%s" % [kind, owner_name, viewport.name]
