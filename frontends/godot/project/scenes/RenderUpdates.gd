extends RefCounted
## Refresh dependent textures in the same frame as a canvas/material change.
## UPDATE_ONCE leaves them asleep afterwards; the engine's low-processor mode
## decides when another frame is needed, including input and native textures.
##
## One frame_pre_draw handler prepares every configured viewport. It first
## samples RenderingServer.has_changed(): the engine clears that flag right
## after frame_pre_draw, so the sample covers every write since the previous
## draw.
##
## A viewport configured with `changes_only` renders only when something
## changed.
##
## Work queued with before_draw() runs after the sample: a new video picture
## then draws the world that shows it, not the workspace canvas too.
static var _viewports: Array[WeakRef] = []
static var _before_draw: Array[Callable] = []
static var _draw_hooks: Array[Callable] = []
## before_draw() suspended low-processor mode to draw one frame.
static var _resume_low_processor := false
## Whether the latest frame_pre_draw saw rendering changes.
static var last_frame_changed := true
## A changes_only viewport also renders this often while frames are drawn,
## for anything that would reach it without a rendering-server write.
const CHANGES_ONLY_REFRESH_MSEC := 250


static func prepare(viewport: SubViewport) -> void:
	if is_instance_valid(viewport) and viewport.get_meta("render_updates_enabled", true):
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		viewport.set_meta("render_updates_prepared_msec", Time.get_ticks_msec())


static func configure(viewport: SubViewport, changes_only := false) -> void:
	_connect()
	viewport.set_meta("render_updates_changes_only", changes_only)
	_viewports.append(weakref(viewport))
	# A live workspace can move between native windows. Reparenting exits and
	# re-enters the tree without another _ready(), so resume its texture updates.
	viewport.tree_entered.connect(prepare.bind(viewport))
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if viewport.is_inside_tree(): prepare(viewport)


## Run `callback` at the next frame_pre_draw, after the change sample, and
## draw this iteration even in low-processor mode. Its rendering writes then
## count neither as changes nor as a reason to draw another frame.
static func before_draw(callback: Callable) -> void:
	_connect()
	if not _before_draw.has(callback): _before_draw.append(callback)
	if OS.low_processor_usage_mode:
		OS.low_processor_usage_mode = false
		_resume_low_processor = true


## Called at every frame_pre_draw after before_draw() work and before the
## viewports prepare. Writes here do not count as changes either.
static func add_draw_hook(callback: Callable) -> void:
	_connect()
	if not _draw_hooks.has(callback): _draw_hooks.append(callback)


static func remove_draw_hook(callback: Callable) -> void:
	_draw_hooks.erase(callback)


static func _connect() -> void:
	if not RenderingServer.frame_pre_draw.is_connected(_dispatch):
		RenderingServer.frame_pre_draw.connect(_dispatch)


static func _dispatch() -> void:
	# Sample before this frame's own writes below.
	prepare_frame(RenderingServer.has_changed())


## One frame_pre_draw. `changed`: rendering state changed since the last draw.
static func prepare_frame(changed: bool) -> void:
	last_frame_changed = changed
	if _resume_low_processor:
		_resume_low_processor = false
		OS.low_processor_usage_mode = true
	var queued := _before_draw
	_before_draw = []
	for callback in queued:
		if callback.is_valid(): callback.call()
	for hook in _draw_hooks.duplicate():
		if hook.is_valid(): hook.call()
	var now := Time.get_ticks_msec()
	var live: Array[WeakRef] = []
	for reference in _viewports:
		var viewport := reference.get_ref() as SubViewport
		if viewport == null: continue
		live.append(reference)
		if viewport.is_inside_tree() and needs_render(viewport, changed, now): prepare(viewport)
	_viewports = live


static func needs_render(viewport: SubViewport, changed: bool, now: int) -> bool:
	if changed or not viewport.get_meta("render_updates_changes_only", false):
		return true
	if now - int(viewport.get_meta("render_updates_prepared_msec", 0)) >= CHANGES_ONLY_REFRESH_MSEC:
		return true
	# Child viewports that render every frame change it without any write.
	for child in viewport.get_children():
		if child is SubViewport and child.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			return true
	return false


static func set_enabled(viewport: SubViewport, enabled: bool) -> void:
	if viewport.get_meta("render_updates_enabled", true) == enabled:
		return
	viewport.set_meta("render_updates_enabled", enabled)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if enabled else SubViewport.UPDATE_DISABLED


## Child SubViewports can render independently of a hidden parent viewport.
static func set_tree_enabled(viewport: SubViewport, enabled: bool) -> void:
	var targets: Array[Node] = [viewport]
	targets.append_array(viewport.find_children("*", "SubViewport", true, false))
	for target: SubViewport in targets:
		if not enabled and not target.has_meta("render_updates_resume_mode"):
			target.set_meta("render_updates_resume_mode", target.render_target_update_mode)
		var mode: int = target.get_meta("render_updates_resume_mode", SubViewport.UPDATE_ONCE)
		set_enabled(target, enabled)
		if enabled:
			target.render_target_update_mode = mode
			if target.has_meta("render_updates_resume_mode"): target.remove_meta("render_updates_resume_mode")
	if enabled: prepare(viewport)


## Unchanged shader writes otherwise keep the rendering server dirty at idle.
static func uniform(material: ShaderMaterial, name: StringName, value: Variant) -> bool:
	var previous: Variant = material.get_shader_parameter(name)
	if previous == value:
		return false
	if typeof(previous) == typeof(value):
		if value is float and is_equal_approx(previous, value): return false
		if value is Vector2 and previous.is_equal_approx(value): return false
		if value is Vector3 and previous.is_equal_approx(value): return false
		if value is Vector4 and previous.is_equal_approx(value): return false
		if value is Basis and previous.is_equal_approx(value): return false
	material.set_shader_parameter(name, value)
	return true
