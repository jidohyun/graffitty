extends "scatter_interruption_smoke.gd"

# Exercise the session capture lifecycle with fixture tabs, without replacing
# the server session or destroying the test's shell.
func session_switch_fixture(index: int) -> void:
 host.session_switch_in_progress = true
 host.world.begin_session_transition()
 await select_tab(index)
 host.world.finish_session_transition()
 host.session_switch_in_progress = false

func switch_and_freeze(index: int) -> void:
 await session_switch_fixture(index)
 var world: Node = host.world
 world.set_process(false)
 var deadline := Time.get_ticks_msec() + 3000
 while world.tab_fx_preparing and Time.get_ticks_msec() < deadline:
  world._process(0.0)
  await process_frame
 check(not world.tab_fx_preparing, "Session destination pixels are ready")
 world._transition_elapsed(0.0)

func play() -> void:
 use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
 await labelled_tabs(["DENSE", "PLAIN"])
 await type("i=0; while [ $i -lt 45 ]; do printf '\\033[38;2;255;0;255m%03d DUST TRANSITION dense text ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\\033[0m\\n' $i; i=$((i+1)); done{enter}")
 await camera_at_rest()
 for path in ["", "flat-2d"]:
  check(host.switch_world(path), "Open renderer " + path)
  await camera_at_rest()
  var world: Node = host.world
  for share in [0.0, 0.1, 1.0]:
   world.fx_cfg.set_option("scene.session_switch", "effect", "fly_away_and_in")
   world._fx_apply_scene()
   await select_tab(0)
   await camera_at_rest()
   # Exercise both endpoints and a density-dependent mix in each renderer.
   var dense_ratio: float = 0.2 if share == 0.1 and path == "flat-2d" else share
   world.fx_cfg.set_option("scene.session_switch", "fly_ratio_sparse", 0.5 if share == 0.1 else share)
   world.fx_cfg.set_option("scene.session_switch", "fly_ratio_dense", dense_ratio)
   var source: Node = host.active_terminal()
   var source_cell: Vector2 = source.get_cell_size()
   var source_count := preload("res://scenes/DustPieces.gd").cells(source, 0).size()
   var source_ratio: float = world.dust_flying_ratio(source)
   check(is_equal_approx(source_ratio, dense_ratio), "Dense tab reaches its configured flying ratio")
   var label: String = ("3d" if path == "" else "2d") + "-" + str(share)
   check(await marked_pixels(label + "-live") > 1000, label + ": dense source visible")
   await switch_and_freeze(1)
   var layers: Array = world.tab_fx_out.filter(func(layer): return layer.has_meta("dust")) if path == "" else world._transition_out.glyphs.filter(func(layer): return layer.has_meta("dust"))
   check(layers.is_empty() == (share == 1.0), label + ": creates dust only below a full flying share")
   for layer in layers:
    var mat: ShaderMaterial = layer._material() if path == "" else layer.material
    var count: int = mat.get_shader_parameter("dust_count")
    check(count > 1000 and count <= 32768, label + ": thousands of actual stroke fragments")
    check(layer.multimesh.instance_count == count, label + ": every instance is a stroke fragment")
   var letters: Array = world.tab_fx_out.filter(func(layer): return layer.get_meta("glyph_layer", false) and not layer.has_meta("dust")) if path == "" else world._transition_out.glyphs.filter(func(layer): return not layer.has_meta("dust"))
   check(letters.is_empty() == (share == 0.0), label + ": zero flying share creates no whole-letter layers")
   var whole_characters := 0
   for layer in letters:
    var mat: ShaderMaterial = layer._material() if path == "" else layer.material
    check(mat.get_shader_parameter("chunked_flight" if path == "" else "glyph_layer"), label + ": flying letters use the original scatter shader path")
    for index in layer.multimesh.instance_count:
     var uv: Color = layer.multimesh.get_instance_custom_data(index)
     whole_characters += 1 + floori(uv.b) if path == "" else roundi(uv.b * float(mat.get_shader_parameter("texture_size").x) / source_cell.x)
    check(layer.multimesh.instance_count > 8, label + ": dense text retains its proportional whole-letter share")
   check(whole_characters == roundi(source_count * source_ratio), label + ": rendered whole-character count follows density (%d/%d)" % [whole_characters, source_count])
   for phase in [0.0, 0.25, 0.5, 1.0]:
    if path == "":
     for layer in world.tab_fx_out: layer.set_fly(world.tab_fx_out_target, phase)
    else: world._transition_out.set_progress(phase)
    var pixels := await marked_pixels(label + "-phase-" + str(phase))
    if phase == 0.0: check(pixels > 1000, label + ": intact captured text at start")
    if phase == 1.0: check(pixels == 0, label + ": no residual text at end")
   world.set_process(true)
   await camera_at_rest()
   var intervals: Array[float] = []
   var previous := [Time.get_ticks_usec()]
   var record := func():
    var now := Time.get_ticks_usec()
    if world.tab_fx_t >= 0.0: intervals.append((now - previous[0]) / 1000.0)
    previous[0] = now
   process_frame.connect(record)
   await session_switch_fixture(0)
   await hold(.8)
   await session_switch_fixture(1)
   await camera_at_rest()
   process_frame.disconnect(record)
   intervals.sort()
   if not intervals.is_empty(): print("DUST_FRAME_MS ", label, " median=", intervals[intervals.size()/2], " p95=", intervals[mini(intervals.size()-1,int(intervals.size()*.95))])
   await hold(1.5)
   check(await marked_pixels(label + "-retired") == 0, label + ": interrupted arrival clears all text")
