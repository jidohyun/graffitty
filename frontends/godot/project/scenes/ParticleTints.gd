extends RefCounted
## Match bursts in input order against rendered text. Several keys can share
## the same pre-output cursor; their colors still belong to distinct glyphs.

## Wide glyphs are stored only at their leading cell. Deletion can target
## either half, so resolve the occupied span before sampling its color.
static func glyph_at(glyphs: Array, cell: Vector2i) -> Dictionary:
	for glyph in glyphs:
		var width := 2 if glyph.get("wide", false) else 1
		if int(glyph.row) == cell.y and cell.x >= int(glyph.col) and cell.x < int(glyph.col) + width:
			return glyph
	return {}

static func refresh(sparks: Array, glyphs: Array, columns: int) -> void:
	if columns <= 0: return
	var cells := {}
	for glyph in glyphs:
		cells[int(glyph.row) * columns + int(glyph.col)] = glyph
	var sources: Array[Dictionary] = []
	var seen := {}
	for p in sparks:
		if p.kind == "flames" or p.unicode <= 0: continue
		var source: Dictionary = p.tint_source
		if seen.has(source.id): continue
		seen[source.id] = true
		sources.append(source)
	var run: Array[Dictionary] = []
	for source in sources:
		if not run.is_empty():
			var previous: Dictionary = run.back()
			var distance: int = _index(source.cell, columns) - _index(previous.cell, columns)
			if source.id != previous.id + 1 or distance < 0 or distance > 2 or run.size() >= 64:
				_resolve(run, cells, columns)
				run.clear()
		run.append(source)
	_resolve(run, cells, columns)

static func _index(cell: Vector2i, columns: int) -> int:
	return cell.y * columns + cell.x

static func _resolve(run: Array[Dictionary], cells: Dictionary, columns: int) -> void:
	if run.is_empty(): return
	# Try the recorded start first. Recover a short stale-render offset only
	# when the complete multi-key sequence matches, never an arbitrary neighbor.
	var anchor: int = run[0].get("resolved", _index(run[0].cell, columns))
	var starts: Array[int] = [anchor]
	if run.size() > 1:
		for offset in range(1, run.size() + 1):
			starts.append(anchor + offset)
			if anchor >= offset: starts.append(anchor - offset)
	for start in starts:
		var at: int = start
		var matched: Array[int] = []
		for source in run:
			if source.has("resolved") and int(source.resolved) != at: break
			if not cells.has(at) or int(cells[at].cp) != int(source.unicode): break
			matched.append(at)
			at += 2 if cells[at].get("wide", false) else 1
		if matched.size() != run.size(): continue
		for i in run.size():
			run[i]["resolved"] = matched[i]
		break
	for source in run:
		var at: int = source.get("resolved", _index(source.cell, columns))
		if cells.has(at) and int(cells[at].cp) == int(source.unicode):
			source["foreground"] = cells[at].foreground
