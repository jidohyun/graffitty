extends RefCounted
## Session dust-and-flight preferences, independent of tab zoom transitions.
const SPARSE_RATIO := 0.5
const DENSE_RATIO := 0.1
const DENSE_COUNT := 1200
var effect := "fly_away_and_in"
var fly_ratio_sparse: float = SPARSE_RATIO
var fly_ratio_dense: float = DENSE_RATIO
var fly_dense_count: int = DENSE_COUNT

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if effect not in ["none", "fly_away_and_in", "fly_away"]:
		errors.append("session_switch.effect must be none, fly_away_and_in or fly_away")
	for key in ["fly_ratio_sparse", "fly_ratio_dense"]:
		var value: float = get(key)
		if not is_finite(value) or value < 0.0 or value > 1.0:
			errors.append("session_switch.%s must be between 0 and 1" % key)
	if fly_dense_count < 1 or fly_dense_count > 1000000:
		errors.append("session_switch.fly_dense_count must be between 1 and 1000000")
	return errors

func apply_effects(effects: RefCounted) -> void:
	for key in ["effect", "fly_ratio_sparse", "fly_ratio_dense", "fly_dense_count"]:
		effects.set_option("scene.session_switch", key, get(key))
