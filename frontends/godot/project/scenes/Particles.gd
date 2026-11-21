extends Node3D
## Typing particles, emitted from the cursor cell on the terminal sheet.
##
## The terminal scene has five particle presets: 'sparks',
## 'basic', 'fireworks', 'flames', 'glitter', plus 'none'. Amount and scale come
## from [scene.typing] particles_amount (6) and particles_scale (1.0).
##
## Native GPUParticles3D rather than a ported shader, per the project's
## preference for Godot's own nodes.

const PRESETS := {
	"sparks": {
		"lifetime": 0.55,
		"speed": [3.0, 7.0],
		"spread": 55.0,
		"gravity": -6.0,
		"scale": [0.10, 0.26],
		"damping": 3.0,
		"ramp": [Color(1.0, 0.95, 0.75), Color(1.0, 0.55, 0.12), Color(0.6, 0.12, 0.0, 0.0)],
	},
	"dots": {
		"lifetime": 0.45,
		"speed": [1.6, 3.2],
		"spread": 40.0,
		"gravity": -2.0,
		"scale": [0.12, 0.22],
		"damping": 2.0,
		"ramp": [Color(1, 1, 1), Color(0.85, 0.9, 1.0), Color(0.6, 0.7, 0.9, 0.0)],
	},
	"fireworks": {
		"lifetime": 1.15,
		"speed": [5.0, 9.0],
		"spread": 180.0,
		"gravity": -5.0,
		"scale": [0.10, 0.20],
		"damping": 1.6,
		"ramp": [Color(1.0, 1.0, 0.85), Color(1.0, 0.35, 0.65), Color(0.25, 0.4, 1.0, 0.0)],
	},
	"flames": {
		"lifetime": 0.8,
		"speed": [1.2, 2.6],
		"spread": 22.0,
		"gravity": 4.5,
		"scale": [0.22, 0.46],
		"damping": 1.2,
		"ramp": [Color(1.0, 0.95, 0.55), Color(1.0, 0.42, 0.06), Color(0.35, 0.05, 0.0, 0.0)],
	},
	"glitter": {
		"lifetime": 1.5,
		"speed": [0.6, 1.8],
		"spread": 120.0,
		"gravity": -1.2,
		"scale": [0.07, 0.15],
		"damping": 0.8,
		"ramp": [Color(1.0, 1.0, 1.0), Color(0.75, 0.95, 1.0), Color(1.0, 0.8, 0.95, 0.0)],
	},
}

var emitter: GPUParticles3D
var _preset := "none"
var _count := 6
var _scale := 1.0


func _ready() -> void:
	emitter = GPUParticles3D.new()
	emitter.emitting = false
	emitter.one_shot = true
	emitter.explosiveness = 1.0
	emitter.local_coords = false
	emitter.draw_order = GPUParticles3D.DRAW_ORDER_LIFETIME
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 0.25
	emitter.draw_pass_1 = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	# Additive quads sum before tonemapping; without this, a dozen overlapping
	# sparks clip to a white blob instead of reading as sparks.
	mat.albedo_color = Color(1, 1, 1, 0.22)
	mat.disable_receive_shadows = true
	emitter.material_override = mat
	add_child(emitter)


func configure(preset: String, count: int, particle_scale: float) -> void:
	_preset = preset
	_count = maxi(count, 1)
	_scale = maxf(particle_scale, 0.01)
	if preset == "none" or not PRESETS.has(preset):
		emitter.emitting = false
		return
	var p: Dictionary = PRESETS[preset]
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.05
	m.direction = Vector3(0, 1, 0)
	m.spread = p["spread"]
	m.initial_velocity_min = p["speed"][0]
	m.initial_velocity_max = p["speed"][1]
	m.gravity = Vector3(0, p["gravity"], 0)
	m.damping_min = p["damping"] * 0.5
	m.damping_max = p["damping"]
	m.scale_min = p["scale"][0] * _scale
	m.scale_max = p["scale"][1] * _scale
	m.angular_velocity_min = -180.0
	m.angular_velocity_max = 180.0

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	ramp.colors = PackedColorArray(p["ramp"])
	var tex := GradientTexture1D.new()
	tex.gradient = ramp
	m.color_ramp = tex

	# Glitter twinkles rather than simply fading.
	if preset == "glitter":
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 0.2))
		curve.add_point(Vector2(0.25, 1.0))
		curve.add_point(Vector2(0.55, 0.35))
		curve.add_point(Vector2(0.8, 0.9))
		curve.add_point(Vector2(1.0, 0.0))
		var ct := CurveTexture.new()
		ct.curve = curve
		m.scale_curve = ct

	emitter.process_material = m
	emitter.lifetime = p["lifetime"]
	emitter.amount = _count


func burst(world_pos: Vector3, basis_up: Vector3, normal: Vector3) -> void:
	## One burst per keystroke, oriented so particles leave the sheet's face.
	if _preset == "none" or not PRESETS.has(_preset):
		return
	emitter.global_position = world_pos + normal * 0.05
	var right := basis_up.cross(normal).normalized()
	emitter.global_transform.basis = Basis(right, basis_up, normal)
	emitter.amount = maxi(_count, 1)
	emitter.restart()
	emitter.emitting = true
