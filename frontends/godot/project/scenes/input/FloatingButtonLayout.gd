extends RefCounted
## Preferred positions belong to a reference canvas, never the obstructed area.
## Nearby controls travel together; separate edge groups can spread on resize.
class Group extends RefCounted:
	var members: Array[String] = []
	var box: Rect2
	var affinity: Vector2

class Pending extends RefCounted:
	var id: String
	var rect: Rect2
	func _init(button_id: String, bounds: Rect2) -> void:
		id = button_id
		rect = bounds

const GAP := 12.0
const NEAR := 40.0

static func attachment(value: float) -> float:
	return 0.0 if value < 1.0 / 3.0 else (1.0 if value > 2.0 / 3.0 else .5)

static func edge(center: Vector2, canvas: Vector2) -> Vector2:
	return Vector2(attachment(center.x / maxf(canvas.x, 1)), attachment(center.y / maxf(canvas.y, 1)))

static func fit(rect: Rect2, bounds: Rect2, occupied: Array[Rect2]) -> Rect2:
	var xs := [clampf(rect.position.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - rect.size.x))]
	var ys := [clampf(rect.position.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - rect.size.y))]
	for other in occupied:
		xs.append(other.end.x + GAP)
		xs.append(other.position.x - GAP - rect.size.x)
		ys.append(other.end.y + GAP)
		ys.append(other.position.y - GAP - rect.size.y)
	var best := Rect2()
	var cost := INF
	for x in xs:
		for y in ys:
			var candidate := Rect2(Vector2(x, y), rect.size)
			if not bounds.encloses(candidate): continue
			var clear := true
			for other in occupied:
				if candidate.grow(GAP * .5).intersects(other.grow(GAP * .5)):
					clear = false
					break
			var distance := candidate.position.distance_squared_to(rect.position)
			if clear and distance < cost:
				best = candidate
				cost = distance
	return best

static func solve(homes: Dictionary, reference: Vector2, canvas: Vector2, bounds: Rect2) -> Dictionary:
	var groups: Array[Group] = []
	for id in homes:
		var members: Array[String] = [id]
		var box: Rect2 = homes[id]
		var affinity := edge(box.get_center(), reference)
		var changed := true
		while changed:
			changed = false
			for i in range(groups.size() - 1, -1, -1):
				if affinity == groups[i].affinity and box.grow(NEAR).intersects(groups[i].box):
					members.append_array(groups[i].members)
					box = box.merge(groups[i].box)
					groups.remove_at(i)
					changed = true
		var group := Group.new()
		group.members = members
		group.box = box
		group.affinity = affinity
		groups.append(group)
	var result := {}
	var occupied: Array[Rect2] = []
	var pending: Array[Pending] = []
	for group in groups:
		var box: Rect2 = group.box
		var wanted := Rect2(box.position + (canvas - reference) * edge(box.get_center(), reference), box.size)
		var placed := fit(wanted, bounds, occupied)
		if not placed.has_area():
			for id in group.members:
				pending.append(Pending.new(id, Rect2(homes[id].position + wanted.position - box.position, homes[id].size)))
			continue
		occupied.append(placed)
		for id in group.members:
			result[id] = homes[id].position + placed.position - box.position
	# Only break a group apart when preserving it cannot fit in the available area.
	for item in pending:
		var placed := fit(item.rect, bounds, occupied)
		if not placed.has_area():
			# A physically undersized window cannot contain every full-size control.
			# Keep each reachable inside the bounds even in that degenerate case.
			placed = Rect2(item.rect.position.clamp(bounds.position, (bounds.end - item.rect.size).max(bounds.position)), item.rect.size)
		occupied.append(placed)
		result[item.id] = placed.position
	return result
