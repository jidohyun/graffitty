extends "../../../../tests/llm-e2e/replay/replay.gd"
const Ports := preload("res://scenes/GraphPorts.gd")

func advertised_ports_ready(keys: Array) -> bool:
 for key in keys:
  var node: Dictionary = host.agent_api.graph.nodes.get(key, {})
  if not Ports.has_port(node, true, 'out') or not Ports.has_port(node, false, 'in'): return false
 return true

func play() -> void:
 root.unfocusable = true
 await camera_at_rest()
 check(is_zero_approx(host.active_terminal().get('cell_padding')), 'Workspace pane padding is not duplicated inside the terminal')
 host.set_tab_transition_effect("scatter")
 var first: int = host.workspace_layout.active
 host.workspace_layout.tab(first).tree.tiling = false
 host.create_terminal_window(host.pane_focus)
 await hold(1.0)
 var keys: Array = host.workspace_view.pane_rects.keys().filter(func(key): return host.is_terminal_pane(key))
 check(keys.size() == 2, 'Two graph nodes are visible')
 for key in keys:
  await host.agent_api.graph.dispatch(int(key.get_slice(':',1)), 'agent.event', {'provider':'adapter', 'event':'SessionStart'})
  await host.agent_api.graph.dispatch(int(key.get_slice(':',1)), 'agent.register', {'name':key,'inputs':[{'id':'in'}],'outputs':[{'id':'out','color':'#ffd47a'}]})
 var advertised_deadline := Time.get_ticks_msec() + 5000
 while not advertised_ports_ready(keys) and Time.get_ticks_msec() < advertised_deadline: await process_frame
 if not check(advertised_ports_ready(keys), 'Owner publishes the registered graph ports'): return
 var connection: Dictionary = host.agent_api.graph.connect_nodes({'from':keys[0], 'from_port':'out', 'to':keys[1], 'to_port':'in', 'send':true})
 check(not connection.has('error'), 'The server accepts the graph connection: ' + str(connection.get('error', 'ok')))
 host.workspace_view.show_overview()
 for key in keys:
  host.sessions[int(key.get_slice(':',1))].term.send_text("printf 'ASCII 한글 中文 😀 \\033[1mBOLD\\033[0m\\n'\r")
 await hold(1.0)
 host.workspace_view._sync_chromium_links()
 var drawing = host.workspace_view.agent_links.wire_layer.still_copy()
 check(not drawing.commands.is_empty(), 'Frozen connection contains wire and arrow geometry')
 var before: Array = drawing.commands.duplicate(true)
 host.workspace_view.agent_links.links.clear()
 check(drawing.commands == before, 'Frozen wires survive changes to live graph')
 drawing.free()
 host.workspace_view._sync_chromium_links()
 # The sync snapshot is unchanged, so explicitly invalidate after our mutation.
 host.workspace_view.agent_links._sync_snapshot.clear()
 host.workspace_view._sync_chromium_links()
 host.toggle_pane_status()
 await hold(0.1)
 host.create_session()
 var deadline := Time.get_ticks_msec() + 10000
 while host.world.tab_fx_out.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
 var panels: Array = host.world.tab_fx_out.filter(func(layer): return layer.has_meta('panel'))
 check(not panels.is_empty(), 'Pane frame and backing participate in transition')
 for layer in panels:
  check(not layer._material().get_shader_parameter('grouped_flight'), 'Pane uses the subtle fade/zoom instead of scattering')
  check(host.world._layer_fly(layer, 0.0) == 0.0, 'Pane starts assembled')
  check(is_equal_approx(host.world._layer_fly(layer, 0.15), 0.5), 'Pane fades during departure start')
  check(is_equal_approx(host.world._layer_fly(layer, 0.30), 1.0), 'Pane is gone before most text departs')
  check(is_equal_approx(host.world._layer_fly(layer, 0.70, true), 1.0), 'Arriving pane stays hidden while text gathers')
  check(is_equal_approx(host.world._layer_fly(layer, 0.15, true), 0.5), 'Pane returns during arrival end')
  check(host.world._layer_fly(layer, 0.0, true) == 0.0, 'Arriving pane finishes assembled')
  check(is_equal_approx(host.world._layer_fly(layer, 1.0), 1.0), 'Pane is fully gone at departure end')
 var glyphs: Array = host.world.tab_fx_out.filter(func(layer): return layer.get_meta('glyph_layer',false))
 if not check(not glyphs.is_empty(), 'Server tab creation starts the outgoing glyph transition'): return
 check(glyphs.all(func(layer): return layer._material().get_shader_parameter('chunked_flight')), 'Text scatters as independent short runs')
 check(glyphs.any(func(layer):
  for i in layer.multimesh.instance_count:
   if floori(layer.multimesh.get_instance_custom_data(i).b)>=2:return true
  return false), 'Rendered pieces contain multiple letters')
 var motions: Array = glyphs.map(func(layer): return layer._material().get_shader_parameter('group_motion'))
 check(motions.all(func(motion): return maxf(absf(motion.x),absf(motion.y))<=0.085 and motion.z>=0.96), 'Camera depth dominates the small lateral drift')
 check(motions.size()>1 and motions[0]!=motions[1], 'Layers retain small variations in travel')
 check(motions.all(func(motion): return motion.w>=0.0 and motion.w<=1.0), 'Each layer has a bounded random timing seed')
 check(glyphs.all(func(layer): return layer.multimesh.mesh.surface_get_array_len(0)>4), 'Flying glyphs have volume geometry')
 # Moving the camera farther away must not increase scatter's world distance.
 var sample_layer = glyphs[0]
 var travel_before: Vector3 = sample_layer._material().get_shader_parameter('group_travel_du')
 var camera_before: Transform3D = host.world.cam.global_transform
 host.world.cam.global_position += host.world.cam.global_basis.z * 100.0
 host.world._group_transition_layer(sample_layer, sample_layer.get_meta('semantic_layer'), true)
 var travel_after: Vector3 = sample_layer._material().get_shader_parameter('group_travel_du')
 check(travel_before.is_equal_approx(travel_after), 'Zooming out does not amplify world-space scatter travel')
 host.world.cam.global_transform = camera_before
 for layer in host.world.tab_fx_out:
  if layer._material().get_shader_parameter('grouped_flight'):
   check(layer._material().get_shader_parameter('group_travel_du').is_equal_approx(host.world.uv_du), 'Text and UI use the same workspace travel scale')
 var names: Array = []
 var groups: Array = []
 for layer in host.world.tab_fx_out:
  if layer.has_meta('graph_layer'): names.append(layer.get_meta('graph_layer'))
  if layer.has_meta('semantic_layer'):
   groups.append(layer.get_meta('semantic_layer'))
   check(layer._material().get_shader_parameter('grouped_flight'), 'Transition uses grouped motion')
 check(preload("res://scenes/PaneStatusDialog.gd").find(host) != null, 'Pane Status remains independent of tab departure')
 check('wires' in names and 'sockets' in names, 'Both connections and sockets participate in departure')
 check(2 in groups and 4 in groups, 'CJK and emoji have separate grouped layers')
 await hold(0.15)
 if DisplayServer.get_name() != 'headless':
  overlay.hide()
  await RenderingServer.frame_post_draw
  root.get_texture().get_image().save_png('/tmp/grouped-scatter-departure.png')
 check(preload("res://scenes/PaneStatusDialog.gd").find(host).visible, 'Pane Status stays visible during tab animation')
 check(host.workspace_view.agent_links.modulate.a == 0.0, 'Live sockets are suppressed during flight')
 for sample in ['middle','late']:
  await hold(0.2)
  if DisplayServer.get_name() != 'headless':
   overlay.hide()
   await RenderingServer.frame_post_draw
   root.get_texture().get_image().save_png('/tmp/grouped-scatter-'+sample+'.png')
 await hold(2.0)
 host.select_workspace(first)
 await hold(0.4)
 if DisplayServer.get_name() != 'headless':
  overlay.hide()
  await RenderingServer.frame_post_draw
  root.get_texture().get_image().save_png('/tmp/grouped-scatter-arrival.png')
 await hold(3.0)
 check(host.world.tab_fx_out.is_empty() and host.world.tab_fx_in.is_empty(), 'Transition captures are released')
 check(host.workspace_view.agent_links.modulate.a == 1.0, 'Live socket visibility is restored')
