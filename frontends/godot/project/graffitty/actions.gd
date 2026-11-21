extends RefCounted
## Actions are ordinary host Callables, shared by rules, menus and prefix bindings.
const Effects := preload("res://graffitty/effects.gd")


static func settle(selector: Dictionary = {}) -> Callable:
	if not _valid(selector): return Callable()
	var selected := Effects.resolve(selector)
	return func(host): host.settle_effects(selected)


static func disable(selector: Dictionary = {}) -> Callable:
	if not _valid(selector): return Callable()
	var selected := Effects.resolve(selector)
	return func(host): return host.disable_effects(selected)


static func _valid(selector: Dictionary) -> bool:
	var errors := Effects.validate(selector)
	for error in errors: push_error(error)
	return errors.is_empty()
