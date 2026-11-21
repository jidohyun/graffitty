extends Node2D
var _preset := "none"
var _count := 6
var _scale := 1.0
## Built-in particle profiles, in source pixels. One persistent pool:
## a new keystroke never restarts particles already in flight.
const CAPACITY := 2048
const PROFILES = preload("res://scenes/TerminalParticles.gd").PROFILES
var sparks: Array[Dictionary] = []
var mesh: MultiMeshInstance2D
var units_per_pixel := 1.0
var cell_height := 26.0
var source_cell := Vector2i(-1, -1)
var source_unicode := 0
var tint_serial := 0
var tint_source: Dictionary = {}
var text_color := Color("#d8dade")
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	mesh = MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = CAPACITY
	mm.visible_instance_count = 0
	set_process(false)
	mesh.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scenes/terminal_particles_2d.gdshader")
	mesh.material = mat
	add_child(mesh)


func configure(preset: String, count: int, particle_scale: float) -> void:
	_preset = preset
	_count = maxi(count, 1)
	_scale = maxf(particle_scale, 0.01)


func varied_color(p: Dictionary, tint: Color) -> Color:
	if p.kind == "sparks":
		var rgb: Vector3 = Vector3(tint.r, tint.g, tint.b).rotated(Vector3.ONE.normalized(), p.hue) * p.brightness
		return Color(clampf(rgb.x, 0, 1), clampf(rgb.y, 0, 1), clampf(rgb.z, 0, 1))
	if p.kind == "glitter":
		return tint.lerp(Color.WHITE, p.glint)
	return Color(
		clampf(tint.r * p.jitter.r, 0, 1),
		clampf(tint.g * p.jitter.g, 0, 1),
		clampf(tint.b * p.jitter.b, 0, 1),
	)


func burst(world_pos: Vector3, basis_up: Vector3, normal: Vector3) -> void:
	if not PROFILES.has(_preset):
		return
	set_process(true)
	var count := _count
	if _preset == "fireworks":
		count = maxi(count / 6, 1)
	tint_serial += 1
	tint_source = {"id": tint_serial, "cell": source_cell, "unicode": source_unicode}
	var right := basis_up.cross(normal).normalized()
	for i in mini(count, CAPACITY - sparks.size()):
		sparks.append(make_particle(_preset, world_pos, right, basis_up, normal))


func make_particle(
	kind: String,
	origin: Vector3,
	right: Vector3,
	up: Vector3,
	normal: Vector3,
) -> Dictionary:
	var q: Array = PROFILES[kind]
	var angle := deg_to_rad(rng.randf_range(q[0] - q[1] * 0.5, q[0] + q[1] * 0.5))
	var speed := rng.randf_range(q[2], q[3])
	var spin := rng.randf_range(-TAU, TAU)
	var seed := clampf((spin / TAU + 1.0) * 0.5, 0.0, 0.999999)
	var velocity := right * cos(angle) * speed + up * sin(angle) * speed
	if kind == "sparks":
		velocity += normal * speed * (0.12 + 0.20 * seed)
	# Speeds, spread and sizes are tuned for a 26-pixel cell; the whole burst
	# follows the text size, so small text gets a small effect.
	var unit := units_per_pixel * cell_height / 26.0
	var p := {
		"kind": kind,
		"position": origin
		+ (right * rng.randf_range(-q[10], q[10]) + up * rng.randf_range(-q[10], q[10]))
		* unit,
		"velocity": velocity,
		"up": up,
		"right": right,
		"normal": normal,
		"unit": unit,
		"age": 0.0,
		"life": rng.randf_range(q[4], q[5]),
		"size": rng.randf_range(q[6], q[7]) * _scale,
		"seed": seed,
		"distance": 0.0,
		"spin": spin,
		"angle": rng.randf_range(0, TAU),
		"source_cell": source_cell,
		"tint_source": tint_source,
		"unicode": source_unicode,
		"shell": kind == "fireworks",
		"count": _count,
		"hue": deg_to_rad(
			(rng.randf_range(-30, 30) + rng.randf_range(-30, 30) + rng.randf_range(-30, 30)) / 3.0
		),
		"brightness": rng.randf_range(0.9, 1.08),
		"glint": rng.randf_range(0.0875, 0.25),
		"jitter": Color(
			rng.randf_range(0.8, 1.15),
			rng.randf_range(0.8, 1.15),
			rng.randf_range(0.8, 1.15),
		),
	}
	p.color = varied_color(p, Color("#ffbf14") if kind == "flames" else text_color)
	return p


func refresh_tints(glyphs: Array, columns: int) -> void:
	preload("res://scenes/ParticleTints.gd").refresh(sparks, glyphs, columns)
	for p in sparks:
		if p.kind != "flames" and p.unicode > 0 and p.tint_source.has("foreground"):
			p.color = varied_color(p, p.tint_source.foreground)


func clear() -> void:
	if sparks.is_empty() and (mesh == null or mesh.multimesh.visible_instance_count == 0):
		set_process(false)
		return
	sparks.clear()
	tint_source.clear()
	if mesh != null: mesh.multimesh.visible_instance_count = 0
	set_process(false)


func _process(delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(delta)
	preload("res://graffitty/frame_profile.gd").add("TerminalParticles2D", Time.get_ticks_usec() - profiled_started)


func _process_body(delta: float) -> void:
	if sparks.is_empty() and mesh.multimesh.visible_instance_count == 0: return
	var remaining := minf(delta, 0.25)
	while remaining > 0.0:
		var dt := minf(remaining, 1.0 / 120.0)
		remaining -= dt
		var shells: Array[Dictionary] = []
		for p in sparks:
			p.age += dt
			if p.age >= p.life:
				if p.shell:
					shells.append(p)
				continue
			var q: Array = PROFILES[p.kind]
			p.velocity = (p.velocity - p.up * float(q[8]) * dt) * maxf(0, 1.0 - float(q[9]) * dt)
			if p.kind == "flames":
				p.velocity += p.right * rng.randf_range(-45, 45) * dt
				p.size *= 1.0 - 0.9 * dt
			p.position += p.velocity * p.unit * dt
			p.distance += p.velocity.length() * dt
			p.angle += p.spin * dt
		sparks = sparks.filter(
			func(p):
				return p.age < p.life,
		)
		for shell in shells:
			for i in mini(shell.count, CAPACITY - sparks.size()):
				var p := make_particle(
					"fireworks",
					shell.position,
					shell.right,
					shell.up,
					shell.normal,
				)
				var angle := rng.randf_range(0, TAU)
				p.position = shell.position
				p.velocity = (shell.right * cos(angle) + shell.up * sin(angle)) * rng.randf_range(
					260,
					420,
				) * 0.7
				p.life = rng.randf_range(0.35, 0.6 * 1.4)
				p.shell = false
				p.color = varied_color(p, shell.color)
				p.unit = shell.unit
				p.unicode = 0
				sparks.append(p)
	mesh.multimesh.visible_instance_count = sparks.size()
	if sparks.is_empty():
		tint_source.clear()
		set_process(false)
	for i in sparks.size():
		var p: Dictionary = sparks[i]
		var t: float = p.age / p.life
		var tint: Color = p.color
		if p.kind == "sparks":
			var heat := clampf(t * (1.35 - 0.5 * (p.life - 0.3) / 0.65), 0, 1)
			var flash := maxf(1.0 - heat / 0.12, 0.0)
			var k := maxf((heat - 0.25) / 0.75, 0)
			var dim := 1.0 - 0.55 * k * k * (3.0 - 2.0 * k)
			tint = tint.lerp(Color.WHITE, 0.1 * flash) * Color(
				dim,
				dim * (1.0 - 0.06 * heat),
				dim * (1.0 - 0.12 * heat),
				1,
			)
		elif p.kind == "flames":
			tint = tint.lerp(Color.RED, t)
		var twinkle: float = PROFILES[p.kind][11]
		tint.a = maxf((1.0 - t) * (1.0 - twinkle + twinkle * sin(p.angle * 3.0)), 0)
		if p.kind == "sparks":
			tint.a *= exp(-1.3863 * p.distance / 380.0)
		var velocity := Vector2(p.velocity.x, p.velocity.y)
		var transform := Transform2D(velocity.angle(), Vector2(p.position.x, p.position.y))
		transform = transform.scaled_local(Vector2.ONE * p.unit)
		mesh.multimesh.set_instance_transform_2d(i, transform)
		mesh.multimesh.set_instance_color(i, tint)
		var speed := maxf(velocity.length(), 0.0001)
		mesh.multimesh.set_instance_custom_data(i, Color(p.size, t, p.seed, speed if p.kind == "sparks" else -speed))
