extends RefCounted
## Tab changes stay on their current surface and restore the saved view.
var effect := "push_pull"

func validate() -> PackedStringArray:
	if effect not in ["none", "push_pull"]:
		return PackedStringArray(["tab_switch.effect must be none or push_pull"])
	return PackedStringArray()

func apply_effects(effects: RefCounted) -> void:
	effects.set_option("scene.tab_switch", "effect", effect)
