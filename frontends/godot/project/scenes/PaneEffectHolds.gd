extends RefCounted
## Effect holds the focused pane's programs asked for (OSC 4723 or the
## `effects.*` RPC).
##
## The server publishes each pane's holds with its topology; this applies the
## focused pane's combined selection through the host's effect gates and
## releases it when focus moves or the holds change.
##
## See docs/developers/automation-and-extensions/effect-holds.md.
const Effects := preload("res://graffitty/effects.gd")
var _release: Callable
var _selected: Array = []


## Effects a pane's holds turn off: the union of every `off`, minus every `on`.
static func resolve(holds: Array) -> Array:
	var off := []
	var on := []
	for hold in holds:
		if not hold is Dictionary: continue
		for name in hold.get("off", []):
			if name is String and name not in off: off.append(name)
		for name in hold.get("on", []):
			if name is String and name not in on: on.append(name)
	return Effects.resolve({"include": off, "exclude": on}).filter(
		func(name): return name in Effects.NAMES)


func update(host: Node, holds: Array) -> void:
	var selected := resolve(holds)
	if selected == _selected and (_release.is_valid() or selected.is_empty()): return
	clear()
	_selected = selected
	if not selected.is_empty(): _release = host.disable_effects(selected)


func selected() -> Array:
	return _selected.duplicate()


func clear() -> void:
	_selected = []
	if _release.is_valid():
		var release := _release
		_release = Callable()
		release.call()
