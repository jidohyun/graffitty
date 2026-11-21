extends SceneTree
## Real GPU regression: transition volume is shaded and disappears exactly at rest.
const Motion := preload("res://scenes/ScatterMotion.gd")
const Pieces := preload("res://scenes/CellShatter.gd")
var failures: Array[String] = []

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures.append(label)

func capture(view: SubViewport, name: String) -> Image:
	for _frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var result := view.get_texture().get_image()
	var folder := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not folder.is_empty(): result.save_png(folder.path_join(name + ".png"))
	return result

func shaded_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.9 and pixel.r > 0.15 and pixel.r < 0.85: count += 1
	return count

func gpu_samples(body: String, count: int) -> PackedFloat32Array:
	var device := RenderingServer.create_local_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = "#version 450\nlayout(local_size_x=64) in;\nlayout(set=0,binding=0,std430) buffer Samples {float samples[];};\n" + FileAccess.get_file_as_string("res://scenes/scatter_motion.gdshaderinc") + "\nvoid main(){uint i=gl_GlobalInvocationID.x;if(i>=" + str(count) + "u)return;" + body + "}"
	var spirv := device.shader_compile_spirv_from_source(source)
	if not check_compile(spirv.compile_error_compute):
		device.free()
		return PackedFloat32Array()
	var shader := device.shader_create_from_spirv(spirv)
	var pipeline := device.compute_pipeline_create(shader)
	var buffer := device.storage_buffer_create(count * 4)
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var bindings := device.uniform_set_create([uniform], shader, 0)
	var compute := device.compute_list_begin()
	device.compute_list_bind_compute_pipeline(compute, pipeline)
	device.compute_list_bind_uniform_set(compute, bindings, 0)
	device.compute_list_dispatch(compute, ceili(float(count) / 64.0), 1, 1)
	device.compute_list_end()
	device.submit()
	device.sync()
	var samples := device.buffer_get_data(buffer).to_float32_array()
	for rid in [bindings, buffer, pipeline, shader]: device.free_rid(rid)
	device.free()
	return samples

func check_settling_curve() -> void:
	# Run shipping shader functions on the GPU, not a CPU approximation.
	var samples := gpu_samples("samples[i]=scatter_flight(float(i)/120.0);", 121)
	if samples.is_empty(): return
	check(samples[80] > 0.55 and samples[80] < 0.7, "Arrival keeps a steady pace instead of covering 90% immediately")
	check(samples[30] > 0.1 and samples[30] < 0.2, "Arrival reserves its last 300 ms for settling")
	# At the final 10 ms, travel is below 0.002% of the full path.
	check(samples[0] == 0.0 and samples[1] < 0.00002 and is_equal_approx(samples[120], 1.0), "Final handoff has exact position and negligible speed")
	var monotonic := true
	for i in range(120): monotonic = monotonic and samples[i] <= samples[i + 1]
	check(monotonic, "Settling never overshoots or reverses direction")

func check_release_schedule() -> void:
	var samples := gpu_samples("float rank=(float(i/4u)+0.5)/100.0;uint lane=i%4u;samples[i]=lane==0u?scatter_release(rank):scatter_clock((lane==1u?10.0:lane==2u?20.0:1.0)/60.0/1.5,rank,false);", 400)
	if samples.is_empty(): return
	var counts := Vector3i.ZERO
	var gentle_start := true
	var first_still_visible := true
	var discrete := true
	for i in 100:
		var release := samples[i * 4]
		if release == 0.0:
			counts.x += 1
			gentle_start = gentle_start and samples[i * 4 + 3] > 0.002 and samples[i * 4 + 3] < 0.006
			first_still_visible = first_still_visible and samples[i * 4 + 1] > 0.08 and samples[i * 4 + 1] < 0.12
		if release < 0.167: counts.y += 1
		if release < 0.334: counts.z += 1
		discrete = discrete and (release == 0.0 or is_equal_approx(release, 1.0 / 6.0) or is_equal_approx(release, 1.0 / 3.0))
	check(counts == Vector3i(20, 80, 100), "Release counts at 0/167/333 ms are 20/80/100: %s" % counts)
	check(discrete, "Every piece belongs to exactly one of three release instants")
	check(gentle_start, "Released chunks start moving visibly within the first 17 ms")
	check(first_still_visible, "First cohort is detached but still in flight at 167 ms")
	var positions := PackedFloat32Array()
	for i in 100: positions.append(float(i % 10) / 9.0)
	var ranks := Pieces.release_ranks(positions, 42)
	check(ranks == Pieces.release_ranks(positions, 42) and ranks != Pieces.release_ranks(positions, 43), "One fixed random sample per capture; a new seed changes the groups")
	var ordered := ranks.duplicate()
	ordered.sort()
	var unique := true
	for i in 99: unique = unique and ordered[i] < ordered[i + 1]
	check(unique, "Sampling without replacement never assigns a piece twice")
	var right_only := true
	var second_halves := Vector2i.ZERO
	var final_halves := Vector2i.ZERO
	for i in 100:
		if ranks[i] < 0.2: right_only = right_only and positions[i] >= 0.5
		elif ranks[i] < 0.8: second_halves[int(positions[i] >= 0.5)] += 1
		else: final_halves[int(positions[i] >= 0.5)] += 1
	check(right_only, "First 20% is randomly sampled only from the right half")
	check(second_halves.x > 0 and second_halves.y > 0 and final_halves.x > 0 and final_halves.y > 0,
		"Second and final groups mix both halves of the remaining text")
	var short_prompt := PackedFloat32Array()
	for x in positions: short_prompt.append(10.0 + x * 20.0)
	check(ranks == Pieces.release_ranks(short_prompt, 42), "Short or offset text keeps the same directional sampling")
	var sparse := PackedFloat32Array()
	sparse.resize(100)
	sparse[99] = 1.0
	var sparse_ranks := Pieces.release_ranks(sparse, 42)
	check(sparse_ranks[99] < 0.2, "A sparse right half still releases first")
	sparse_ranks.sort()
	check(sparse_ranks == ordered, "Sparse text preserves every piece and the 20/60/20 proportions")
	check(Pieces.release_ranks(PackedFloat32Array(), 42).is_empty()
		and Pieces.release_ranks(PackedFloat32Array([0.3]), 42) == PackedFloat32Array([0.0]), "Empty and single-piece captures remain valid")
	var mixed_rows := 0
	for row in 10:
		var early := 0
		for col in 10: early += int(ranks[row * 10 + col] < 0.2)
		if early > 0 and early < 10: mixed_rows += 1
	check(mixed_rows >= 6, "Random first group is spread vertically: %d of 10 rows" % mixed_rows)
	var literals := PackedStringArray()
	for rank in ranks: literals.append("%.9f" % rank)
	var body := "const float ranks[100]=float[100](" + ",".join(literals) + ");const float times[5]=float[5](0.05,0.16,0.17,0.33,0.34);samples[i]=scatter_clock(times[i%5u]/1.5,ranks[i/5u],false);"
	var poses := gpu_samples(body, 500)
	if poses.is_empty(): return
	var moving := PackedInt32Array([0, 0, 0, 0, 0])
	for i in poses.size(): moving[i % 5] += int(poses[i] > 0.0)
	check(moving == PackedInt32Array([20,20,80,80,100]), "No wave between stages: moving counts at 50/160/170/330/340 ms are %s" % moving)

func check_arrival_groups() -> void:
	# Actual incoming GPU clocks: 20%, then 60% more, then the remaining 20%.
	var poses := gpu_samples("const float times[10]=float[10](0.05,0.16,0.17,0.33,0.34,1.25,1.36,1.37,1.53,1.54);float rank=(float(i/10u)+0.5)/100.0;samples[i]=scatter_clock(1.0-times[i%10u]/SCATTER_ARRIVAL,rank,true);", 1000)
	if poses.is_empty(): return
	var moving := PackedInt32Array([0, 0, 0, 0, 0])
	var landed := PackedInt32Array([0, 0, 0, 0, 0])
	var grouped := true
	for rank in 100:
		var representative := 0 if rank < 20 else (20 if rank < 80 else 80)
		for step in 10:
			var value := poses[rank * 10 + step]
			grouped = grouped and absf(value - poses[representative * 10 + step]) < 0.000001
			if step < 5: moving[step] += int(value < 0.999999)
			else: landed[step - 5] += int(value < 0.000000001)
	check(moving == PackedInt32Array([20, 20, 80, 80, 100]), "Incoming 20/60/20 groups start at 0/167/333 ms: %s" % moving)
	check(grouped, "Arrival uses three groups instead of a per-character wave")
	check(landed == moving, "Every incoming group keeps its full 1.2 second flight and settles in the same order: %s" % landed)
	var clocks := gpu_samples("float phase=float(i%121u)/120.0;float rank=(float(i/121u)+0.5)/100.0;samples[i]=scatter_clock(phase,rank,true);", 12100)
	var matches := true
	for i in clocks.size():
		matches = matches and absf(clocks[i] - Motion.clock(float(i % 121) / 120.0, (float(i / 121) + 0.5) / 100.0, true)) < 0.000001
	check(matches, "CPU and GPU agree across arrival delays, landing, and all three groups")
	# Mirror the arc around each letter's view ray, keeping depth and vertical
	# jitter. An incoming character must originate on the right near the eye.
	var paths := gpu_samples("uint pose=i/6u;float flight=float(pose%121u)/120.0;uint grid=pose/121u;vec2 uv=vec2(float(grid%5u),float(grid/5u))*0.25;vec2 jitter=fract(vec2(float(grid))*vec2(0.61803398875,0.41421356237));vec2 wind=scatter_wind(uv,jitter);vec3 travel=scatter_travel(flight,(uv-0.5)*2.0,wind,scatter_drift(uv,jitter,wind),i%6u>=3u);samples[i]=travel[i%3u];", 18150)
	var mirrored := true
	var from_right := true
	for grid in 25:
		var offset := (Vector2(grid % 5, grid / 5) * 0.25 - Vector2(0.5, 0.5)) * 2.0
		for frame in 121:
			var i := (grid * 121 + frame) * 6
			var leaving := Vector3(paths[i], paths[i + 1], paths[i + 2])
			var incoming := Vector3(paths[i + 3], paths[i + 4], paths[i + 5])
			mirrored = mirrored and absf(incoming.x + leaving.x + offset.x * incoming.z * 2.0) < 0.000001 and absf(incoming.y - leaving.y) < 0.000001 and incoming.z == leaving.z
			if frame >= 72 and frame <= 79:
				from_right = from_right and incoming.x + offset.x * incoming.z > 0.0
			if frame == 0: mirrored = mirrored and incoming.is_zero_approx()
	check(mirrored, "Arrival mirrors the continuous arc horizontally and lands at the exact original letter")
	check(from_right, "Incoming letters approach from the right while passing close to the camera")

func check_departure_acceleration() -> void:
	var samples := gpu_samples("samples[i]=scatter_departure(float(i)*0.001);", 1101)
	if samples.is_empty(): return
	check(samples[0] == 0.0 and samples[1] < 0.0003 and is_equal_approx(samples[1100], 1.0), "Departure starts gently and still completes in 1100 ms")
	var accelerating := true
	for i in range(1, 150):
		accelerating = accelerating and samples[i + 1] - samples[i] >= samples[i] - samples[i - 1] - 0.000001
	check(accelerating, "Departure smoothly accelerates through the first 150 ms")
	var cruise := samples[701] - samples[700]
	check(absf(samples[150] - samples[149] - cruise) < 0.000001 and absf(samples[151] - samples[150] - cruise) < 0.000001, "Gentle lift joins cruising speed without a velocity jump")
	check(samples[50] > 0.01 and samples[100] > 0.04 and samples[200] > 0.12, "No long dwell: the first 50/100/200 ms already show forward motion")

func check_camera_approach() -> void:
	# Sample the production GPU path across the sheet with fixed per-piece jitter.
	var samples := gpu_samples("uint pose_index=i/3u;float flight=float(pose_index%121u)/120.0;uint grid=pose_index/121u;vec2 uv=vec2(float(grid%5u),float(grid/5u))*0.25;vec2 offset=(uv-0.5)*2.0;vec2 jitter=fract(vec2(float(grid))*vec2(0.61803398875,0.41421356237));vec2 wind=scatter_wind(uv,jitter);vec3 travel=scatter_travel(flight,offset,wind,scatter_drift(uv,jitter,wind),false);samples[i]=travel[i%3u];", 9075)
	if samples.is_empty(): return
	var approaching := true
	var forward_start := true
	var close_approach := true
	var leftward := true
	var no_vertical_reversal := true
	var right_down_then_left := 0
	var continuous_pull := true
	var max_turn := 0.0
	var cpu_match := true
	var min_bend := 90.0
	var max_bend := 0.0
	var min_heading := 90.0
	var max_heading := -90.0
	for grid in 25:
		var uv := Vector2(grid % 5, grid / 5) * 0.25
		var offset := (uv - Vector2(0.5, 0.5)) * 2.0
		var jitter := Vector2(fposmod(grid * 0.61803398875, 1.0), fposmod(grid * 0.41421356237, 1.0))
		var wind := Motion.wind(uv, jitter)
		var drift := Motion.drift(uv, jitter, wind)
		var heading := rad_to_deg(atan2(wind.y, -wind.x))
		min_heading = minf(min_heading, heading)
		max_heading = maxf(max_heading, heading)
		var previous_side := Vector2.ZERO
		var previous_tangent := Vector3.ZERO
		var started_right_down := false
		for frame in 121:
			var index := (grid * 121 + frame) * 3
			var travel := Vector3(samples[index], samples[index + 1], samples[index + 2])
			var side := Vector2(travel.x, travel.y) + offset * travel.z
			var expected := drift * (float(frame) / 120.0) + wind * Motion.wind_distance(float(frame) / 120.0)
			cpu_match = cpu_match and side.distance_to(expected) < 0.00003
			if frame == 0: forward_start = forward_start and travel.is_zero_approx()
			if frame == 1:
				forward_start = forward_start and side.length() / travel.z < 0.05
				started_right_down = side.x > 0.00004 and side.y > 0.00004
			if frame == 54:
				# More than 3x the original apparent size, still near its view ray.
				close_approach = close_approach and 1.0 / (1.0 - travel.z) > 3.0 and side.length() / (1.0 - travel.z) < 0.12
			if frame > 0:
				approaching = approaching and travel.z > samples[index - 1]
				var tangent := Vector3((side.x - previous_side.x) * 120.0, (side.y - previous_side.y) * 120.0, 1.5)
				if frame > 1 and frame <= 79:
					max_turn = maxf(max_turn, rad_to_deg(previous_tangent.angle_to(tangent)))
					continuous_pull = continuous_pull and tangent.x <= previous_tangent.x + 0.00003
				if frame >= 60: leftward = leftward and tangent.x < 0.0
				if frame == 60 and started_right_down and tangent.x < 0.0 and tangent.y > 0.0:
					right_down_then_left += 1
				previous_tangent = tangent
				no_vertical_reversal = no_vertical_reversal and (side.y - previous_side.y) * wind.y >= -0.000001
			if frame == 103:
				var slope := (side - previous_side).length() / (travel.z - samples[index - 1])
				var bend := rad_to_deg(atan(slope))
				min_bend = minf(min_bend, bend)
				max_bend = maxf(max_bend, bend)
			previous_side = side
	check(forward_start, "Every piece starts toward the camera before bending sideways")
	check(close_approach, "Text reaches 3x apparent size before substantial sideways drift")
	check(approaching and leftward, "Wind eventually curves every path left while depth keeps advancing past the camera")
	check(right_down_then_left >= 3, "Some pieces drift down-right before continuously curving left: %d paths" % right_down_then_left)
	check(continuous_pull and max_turn < 2.0, "Visible trajectories turn continuously under leftward acceleration: maximum %.3f degrees per path sample" % max_turn)
	check(min_heading < -30.0 and max_heading > 30.0 and min_heading >= -60.01 and max_heading <= 60.01,
		"Wind includes clear upper-left and lower-left directions: %.2f–%.2f" % [min_heading, max_heading])
	check(no_vertical_reversal, "Vertical drift and wind agree, with no down-then-up reversal")
	check(min_bend >= 29.99 and max_bend <= 70.01 and max_bend - min_bend > 20.0,
		"Late wind tangents vary within 30–70 degrees: %.2f–%.2f" % [min_bend, max_bend])
	check(cpu_match, "2D UI and GPU glyphs follow the same curved wind path")
	var directions := gpu_samples("uint grid=i/4u;vec2 uv=vec2(float(grid%5u),float(grid/5u))*0.25;vec2 wind=scatter_wind(uv+(i%4u<2u?vec2(0.0):vec2(0.005)),vec2(0.25,0.75));samples[i]=wind[i%2u];", 100)
	var coherent := true
	for grid in 25:
		var a := Vector2(directions[grid * 4], directions[grid * 4 + 1])
		var b := Vector2(directions[grid * 4 + 2], directions[grid * 4 + 3])
		coherent = coherent and absf(rad_to_deg(atan(a.length()) - atan(b.length()))) < 0.4
		coherent = coherent and absf(rad_to_deg(a.angle_to(b))) < 0.25
	check(coherent, "Neighbouring positions share a smoothly changing gust")
	var opacity := gpu_samples("float f=float(i)/120.0;samples[i]=scatter_opacity(f);", 121)
	var hidden_fade := true
	for i in range(101): hidden_fade = hidden_fade and opacity[i] > 0.99999
	check(hidden_fade and opacity[120] == 0.0, "Fade starts only after pieces have passed the eye by 25% of their original depth")

func check_retirement() -> void:
	# Sample every arrival phase and group on the actual GPU. The first small
	# step must preserve velocity; subsequent steps must never race to catch up.
	var samples := gpu_samples("uint run=i/151u;float phase=(float(run%11u)+0.5)/12.0;float rank=(float(run/11u)+0.5)/10.0;samples[i]=scatter_retire(phase,rank,float(i%151u)*0.01);", 16610)
	if samples.is_empty(): return
	var continuous := true
	var bounded := true
	var cpu_match := true
	for run in 110:
		var phase := (float(run % 11) + 0.5) / 12.0
		var rank := (float(run / 11) + 0.5) / 10.0
		var start := Motion.clock(phase, rank, true)
		continuous = continuous and absf(samples[run * 151] - start) < 0.00001
		for i in 151:
			var value := samples[run * 151 + i]
			cpu_match = cpu_match and absf(value - Motion.retire_flight(phase, rank, i * 0.01)) < 0.00015
			bounded = bounded and value >= -0.00001
			if i > 0: bounded = bounded and absf(value - samples[run * 151 + i - 1]) / 0.01 < 1.1
		bounded = bounded and samples[run * 151 + 150] > 1.0
	check(continuous, "Interrupted arrivals retain every chunk's exact displayed position")
	check(bounded, "Retirement stays within normal flight speed, never passes through the pane, and finishes")
	check(cpu_match, "2D UI and 3D GPU use the same velocity-preserving retirement")
	var rates := gpu_samples("float phase=(float(i%11u)+0.5)/12.0;float rank=(float(i/11u)+0.5)/10.0;float before=(scatter_clock(phase-0.0001,rank,true)-scatter_clock(phase+0.0001,rank,true))/(0.0002*SCATTER_ARRIVAL);float after=(scatter_retire(phase,rank,0.00005)-scatter_retire(phase,rank,0.0))/0.00005;samples[i]=abs(before-after);", 110)
	var error := 0.0
	for value in rates: error = maxf(error, value)
	check(error < 0.01, "Interruption preserves the incoming velocity: maximum difference %.6f" % error)
	var speeds := gpu_samples("float phase=(float(i%101u)+0.5)/102.0;float rank=(float(i/101u)+0.5)/10.0;samples[i]=abs(scatter_clock(phase-0.0001,rank,true)-scatter_clock(phase+0.0001,rank,true))/(0.0002*SCATTER_ARRIVAL);", 1010)
	var peak := 0.0
	for value in speeds: peak = maxf(peak, value)
	check(peak < 1.1 / Motion.DISTANCE, "Arrival peak speed matches departure within 10%")

func check_frame_rates() -> void:
	# Advance the same 167 ms at 12, 30, 60, 120 and 144 FPS. Each shader receives
	# elapsed seconds, so changing the number of draws cannot change its pose.
	var samples := gpu_samples("uint rate=i%5u;float fps=rate==0u?12.0:rate==1u?30.0:rate==2u?60.0:rate==3u?120.0:144.0;float elapsed=0.0;for(uint frame=0u;frame<uint(fps/6.0);frame++){elapsed+=1.0/fps;}float rank=(float(i/5u)+0.5)/100.0;samples[i]=scatter_clock(elapsed/1.5,rank,false);", 500)
	if samples.is_empty(): return
	var error := 0.0
	for i in 100:
		for rate in range(1, 5): error = maxf(error, absf(samples[i * 5] - samples[i * 5 + rate]))
	check(error < 0.000001, "12/30/60/120/144 FPS produce the same timed pose: error %.9f" % error)

func check_compile(error: String) -> bool:
	check(error.is_empty(), "Production settling shader compiles: " + error)
	return error.is_empty()

func run() -> void:
	check_settling_curve()
	check_release_schedule()
	check_arrival_groups()
	check_departure_acceleration()
	check_frame_rates()
	check_camera_approach()
	check_retirement()
	var source := SubViewport.new()
	source.disable_3d = true
	source.transparent_bg = true
	source.size = Vector2i(256, 256)
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	# An asymmetric stroke mask exposes side faces and holes without new fonts.
	for rect in [Rect2(72, 40, 32, 176), Rect2(72, 40, 116, 32), Rect2(72, 104, 88, 32)]:
		var stroke := ColorRect.new()
		stroke.position = rect.position
		stroke.size = rect.size
		stroke.color = Color.WHITE
		source.add_child(stroke)
	var neighbour := ColorRect.new()
	neighbour.position = Vector2(128, 0)
	neighbour.size = Vector2(128, 256)
	neighbour.color = Color.RED
	source.add_child(neighbour)
	var view := SubViewport.new()
	view.size = Vector2i(512, 512)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new()
	camera.position.z = 5.0
	view.add_child(camera)
	var piece := Pieces.new()
	view.add_child(piece)
	var whole := Rect2(0, 0, 256, 256)
	piece.build_regions(source, [Rect2(0, 0, 128, 256)], whole, Vector3(-1, 1, 0), Vector3(2, 0, 0), Vector3(0, -2, 0), Vector2.ZERO, 0)
	piece.set_progress(1.0)
	piece.set_appearance(1.0, 1.0)
	var material: ShaderMaterial = piece._material()
	material.set_shader_parameter("grouped_flight", true)
	material.set_shader_parameter("chunked_flight", true)
	material.set_shader_parameter("chunk_seed", 7.3)
	material.set_shader_parameter("group_travel_du", Vector3(2, 0, 0))
	material.set_shader_parameter("group_travel_dv", Vector3(0, -2, 0))
	piece.set_fly(Vector3(0, 0, 6.2), 0.0)
	piece.set_thickness(0.0)
	var flat := await capture(view, "rest-flat")
	piece.enable_flight_volume()
	Pieces.assign_release_ranks([piece])
	piece.set_thickness(0.16)
	var rest := await capture(view, "rest-volume")
	check(flat.get_data() == rest.get_data(), "Volume leaves assembled text pixel-identical")
	var best_sides := 0
	var leaked_pixels := 0
	for phase in [0.1, 0.2, 0.3, 0.4]:
		piece.set_fly(Vector3(0, 0, 6.2), phase)
		piece.set_thickness(0.0)
		var face := await capture(view, "flight-flat-%s" % phase)
		piece.set_thickness(0.16)
		var volume := await capture(view, "flight-volume-%s" % phase)
		for y in volume.get_height():
			for x in volume.get_width():
				var pixel := volume.get_pixel(x, y)
				if pixel.a > 0.1 and pixel.r > pixel.g + 0.2: leaked_pixels += 1
		best_sides = maxi(best_sides, shaded_pixels(volume) - shaded_pixels(face))
	check(leaked_pixels == 0, "Moving text never samples its neighbouring red run: %d pixels" % leaked_pixels)
	check(best_sides > 50, "Tumbling stroke has visible shaded side faces: %d pixels" % best_sides)
	# Flight 0.82 has depth 1.23: already behind the camera, still fully opaque.
	piece.set_fly(Vector3(0, 0, 6.2), (0.82 * Motion.DISTANCE + 0.06) / Motion.DEPARTURE)
	var past_eye := await capture(view, "past-eye-before-fade")
	var visible := 0
	for y in past_eye.get_height():
		for x in past_eye.get_width(): visible += int(past_eye.get_pixel(x, y).a > 0.01)
	check(visible == 0, "Geometry is clipped out of view before opacity starts fading: %d pixels" % visible)
	piece.set_fly(Vector3(0, 0, 6.2), 0.0)
	var landed := await capture(view, "landed")
	check(flat.get_data() == landed.get_data(), "Landing removes every extra face without changing the text")
	print("SCATTER_DEPTH_PASS" if failures.is_empty() else "SCATTER_DEPTH_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
