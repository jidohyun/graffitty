extends RefCounted
## Events run once; scopes retain an action until their conditions stop matching.
var event := ""
var scoped := false
var conditions: Dictionary = {}
var action: Callable


static func on(name: String, where: Dictionary, callback: Callable) -> RefCounted:
	var rule = load("res://graffitty/rule.gd").new()
	rule.event = name
	rule.conditions = where.duplicate(true)
	rule.action = callback
	return rule


static func while_active(where: Dictionary, callback: Callable) -> RefCounted:
	var rule = on("", where, callback)
	rule.scoped = true
	return rule


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not scoped and event not in ["app_changed", "focus_changed"]:
		errors.append("Unknown rule event: " + event)
	if not action.is_valid():
		errors.append("Rule action must be a valid Callable receiving the host")
	for key in conditions:
		if key not in ["app", "pane"]:
			errors.append("Unknown rule condition: " + str(key))
		var value = conditions[key]
		if value is String:
			continue
		if not value is Array or not value.all(func(item): return item is String):
			errors.append("Rule conditions require a string or an array of strings")
	return errors


func matches(name: String, context: Dictionary) -> bool:
	if not scoped and name != event:
		return false
	for key in conditions:
		var expected = conditions[key]
		var actual = context.get(key, "")
		if expected is Array:
			if actual not in expected: return false
		elif actual != expected:
			return false
	return true
