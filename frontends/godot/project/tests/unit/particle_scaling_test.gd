extends "res://tests/unit/test_case.gd"

const RENDERERS := [preload("res://scenes/TerminalParticles2D.gd"), preload("res://scenes/TerminalParticles.gd")]
const ORIGIN := Vector3(17, 29, 3)


func pool_for(script: GDScript, height: float):
	var pool = script.new()
	pool._ready()
	pool.cell_height = height
	pool.rng.seed = 731
	for i in 8:
		pool.sparks.append(pool.make_particle("sparks", ORIGIN, Vector3.RIGHT, Vector3.UP, Vector3.BACK))
	return pool


func test_spark_spread_size_and_flight_scale_with_font_in_both_renderers() -> void:
	for script in RENDERERS:
		for ratio in [0.25, 0.5, 2.0]:
			var reference = pool_for(script, 26.0)
			var scaled = pool_for(script, 26.0 * ratio)
			for frame in 5:
				for i in reference.sparks.size():
					var a: Dictionary = reference.sparks[i]
					var b: Dictionary = scaled.sparks[i]
					var label := "%s scale=%s frame=%s particle=%s" % [script.resource_path.get_file(), ratio, frame, i]
					expect((b.position - ORIGIN).is_equal_approx((a.position - ORIGIN) * ratio), label + ": spread and simulated flight scale around the cursor")
					expect(is_equal_approx(b.size * b.unit, a.size * a.unit * ratio), label + ": thickness scales once, not twice")
					expect((b.velocity * b.unit).is_equal_approx(a.velocity * a.unit * ratio), label + ": speed and gravity scale together")
					expect(is_equal_approx(a.life, b.life) and is_equal_approx(a.age, b.age), label + ": font size does not change lifetime")
				reference._process(1.0 / 60.0)
				scaled._process(1.0 / 60.0)
			reference.free()
			scaled.free()
