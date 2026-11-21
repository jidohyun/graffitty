extends RefCounted
## Copies the displayed scene graph and its render dependencies without session
## or input scripts. Text stays native drawing state,
## meshes keep their geometry, and viewport samplers point to independent views.
var _nodes := {}
var _textures := {}
var _resources := {}
var _worlds := {}
var _excluded: Array[Node] = []
var _root: SubViewport


static func workspace(host: Node) -> SubViewport:
	var capture := new()
	capture._index(host)
	capture._excluded = [host.workspace_view.tab_bar]
	var source: Viewport = host.get_viewport()
	var view := SubViewport.new()
	view.size = Vector2i(source.get_texture().get_size())
	view.size_2d_override = Vector2i(source.get_visible_rect().size)
	view.size_2d_override_stretch = true
	view.transparent_bg = source.transparent_bg
	view.use_hdr_2d = source.use_hdr_2d
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	capture._root = view
	view.add_child(capture._copy_node(host.layout_root))
	# Fixed menus and overlays live outside the world/layout tree.
	for child in host.get_children():
		if child is CanvasLayer: view.add_child(capture._copy_node(child))
	return view


## `sources` own viewports that `source` samples from outside its subtree,
## such as a Chromium page's decoder view.
##
## The copy keeps its own snapshot of them: a live view can be freed while a
## transition still shows its last frame.
static func control(source: Control, sources: Array = []) -> Control:
	var capture := new()
	for node in sources: capture._index(node)
	var copy := capture._copy_node(source) as Control
	for retained in capture._nodes.values():
		if retained is SubViewport and retained.get_parent() == null: copy.add_child(retained)
	return copy


func _index(node: Node) -> void:
	if node is SubViewport: _textures[node.get_texture().get_rid()] = node
	for child in node.get_children(): _index(child)


func _copy_resource(value: Resource) -> Resource:
	if value == null: return null
	var id := value.get_instance_id()
	if _resources.has(id): return _resources[id]
	if value is ViewportTexture and _textures.has(value.get_rid()):
		return _copy_node(_textures[value.get_rid()]).get_texture()
	if value is ShaderMaterial:
		var copy := value.duplicate() as ShaderMaterial
		_resources[id] = copy
		if value.shader != null:
			for uniform in value.shader.get_shader_uniform_list():
				var parameter: Variant = value.get_shader_parameter(uniform.name)
				if parameter is Resource: copy.set_shader_parameter(uniform.name, _copy_resource(parameter))
		if value.next_pass != null: copy.next_pass = _copy_resource(value.next_pass)
		return copy
	if value is AtlasTexture:
		var copy := value.duplicate() as AtlasTexture
		_resources[id] = copy
		copy.atlas = _copy_resource(value.atlas)
		return copy
	if value is Compositor:
		var copy := Compositor.new()
		_resources[id] = copy
		for effect in value.compositor_effects:
			copy.compositor_effects.append(effect.presentation_copy() if effect.has_method("presentation_copy") else effect.duplicate())
		return copy
	if value is MultiMesh:
		# Native code may resize the server-side multimesh without touching the
		# resource, so duplicate() pairs a stale count with the real buffer and
		# the engine rejects it. Read count and buffer from the server together.
		var copy := MultiMesh.new()
		_resources[id] = copy
		copy.transform_format = value.transform_format
		copy.use_colors = value.use_colors
		copy.use_custom_data = value.use_custom_data
		copy.mesh = _copy_resource(value.mesh)
		var count := RenderingServer.multimesh_get_instance_count(value.get_rid())
		copy.instance_count = count
		if count > 0: copy.buffer = RenderingServer.multimesh_get_buffer(value.get_rid())
		copy.visible_instance_count = RenderingServer.multimesh_get_visible_instances(value.get_rid())
		copy.custom_aabb = value.custom_aabb
		return copy
	if value is Material or value is CameraAttributes or value is Environment or value is Theme or value is StyleBox or value is Sky:
		var copy := value.duplicate()
		_resources[id] = copy
		# Pane styles and themes can be edited in place during a world switch.
		# Duplicate those bindings while keeping font and media assets shared.
		for property in value.get_property_list():
			if not property.usage & PROPERTY_USAGE_STORAGE or property.usage & PROPERTY_USAGE_READ_ONLY: continue
			var child: Variant = value.get(property.name)
			if child is Resource and property.name != "script": copy.set(property.name, _copy_resource(child))
		if value is CameraAttributes and value.has_meta("presentation_dof"):
			var lens: Array = value.get_meta("presentation_dof")
			RenderingServer.camera_attributes_set_dof_blur(copy.get_rid(), lens[0], lens[1], lens[2], lens[3], lens[4], lens[5], lens[6])
		return copy
	# Fonts, meshes and real media are reference-owned immutable assets.
	return value


func _copy_node(source: Node) -> Node:
	if _nodes.has(source): return _nodes[source]
	var copy: Node
	if source.is_class("Terminal"):
		var state: RefCounted = source.capture_render_state()
		if state == null: return Control.new()
		var viewport: SubViewport = source.get_viewport()
		var logical := Vector2(preload("res://scenes/TerminalEffects.gd").layout_size(viewport)).max(Vector2.ONE)
		var density := Vector2(viewport.size) / logical * viewport.canvas_transform.get_scale().abs()
		copy = state.create_view(maxf(density.x, density.y))
		_nodes[source] = copy
		return copy
	if source.has_method("presentation_copy"):
		copy = source.presentation_copy()
		_nodes[source] = copy
		_remap_resources(copy)
		return copy
	if source.is_class("ModView"):
		# A duplicate has no script of its own; it paints the live copy's frame.
		copy = ClassDB.instantiate("ModView")
		copy.mirror(source)
		copy.position = source.position
		copy.size = source.size
		copy.scale = source.scale
		copy.custom_minimum_size = source.custom_minimum_size
		copy.process_mode = Node.PROCESS_MODE_DISABLED
		_nodes[source] = copy
		return copy
	if source.get_script() == preload("res://scenes/GraphWireLayer.gd"):
		copy = source.still_copy()
		copy.transform = source.transform
		copy.process_mode = Node.PROCESS_MODE_DISABLED
		_nodes[source] = copy
		return copy
	if source is SubViewport:
		copy = SubViewport.new()
	elif source is CanvasItem or source is Node3D or source is CanvasLayer or source is WorldEnvironment:
		copy = ClassDB.instantiate(source.get_class())
	else:
		copy = Node.new()
	_nodes[source] = copy
	copy.name = source.name
	if copy.get_class() == source.get_class():
		for property in source.get_property_list():
			var key: String = property.name
			if not property.usage & PROPERTY_USAGE_STORAGE or property.usage & PROPERTY_USAGE_READ_ONLY: continue
			if key in ["script", "owner", "process_mode", "unique_name_in_owner", "world_2d", "world_3d", "own_world_3d"] or key.begins_with("metadata/"): continue
			var value: Variant = source.get(key)
			if value is Resource: value = _copy_resource(value)
			copy.set(key, value)
	copy.process_mode = Node.PROCESS_MODE_DISABLED
	if copy is Camera3D:
		# Physical attributes overwrite the projection when assigned. The live
		# renderer deliberately applies its off-axis projection afterwards too.
		copy.keep_aspect = source.keep_aspect
		copy.projection = source.projection
		copy.fov = source.fov
		copy.size = source.size
		copy.frustum_offset = source.frustum_offset
		copy.near = source.near
		copy.far = source.far
		if source.get_meta("frustum_vertical_aspect", false):
			RenderingServer.camera_set_use_vertical_aspect(copy.get_camera_rid(), true)
			copy.set_meta("frustum_vertical_aspect", true)
	if copy is Control:
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		copy.focus_mode = Control.FOCUS_NONE
		if source.has_meta("port_color"):
			var dot := preload("res://scenes/GraphWireLayer.gd").new()
			dot.frozen = true
			dot.commands = [[&"draw_circle", [source.size * 0.5, 4.0, source.get_meta("port_color"), true, -1.0, true]]]
			copy.add_child(dot)
	if copy is SubViewport:
		copy.gui_disable_input = true
		copy.render_target_update_mode = SubViewport.UPDATE_ONCE
		# RenderingServer attaches the canvas on tree entry. Setting a nonidentity
		# transform before that produces an engine error and loses the crop.
		copy.tree_entered.connect(_restore_canvas.bind(copy, source.canvas_transform, source.global_canvas_transform), CONNECT_ONE_SHOT)
		var world: World3D = source.find_world_3d()
		if not _worlds.has(world): _worlds[world] = World3D.new()
		copy.world_3d = _worlds[world]
	for child in source.get_children():
		if child is Window or child in _excluded: continue
		var retained := _copy_node(child)
		if retained.get_parent() == _root and _root != null:
			retained.reparent(copy, false)
		elif retained.get_parent() == null:
			copy.add_child(retained)
	# Texture dependencies can be discovered before their original parent.
	if _root != null and copy is SubViewport and copy.get_parent() == null:
		_root.add_child(copy)
	return copy


static func _restore_canvas(view: SubViewport, local: Transform2D, global: Transform2D) -> void:
	view.canvas_transform = local
	view.global_canvas_transform = global


func _remap_resources(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	for property in node.get_property_list():
		if not property.usage & PROPERTY_USAGE_STORAGE or property.usage & PROPERTY_USAGE_READ_ONLY: continue
		if property.name == "script": continue
		var value: Variant = node.get(property.name)
		if value is Resource: node.set(property.name, _copy_resource(value))
	for child in node.get_children(): _remap_resources(child)
