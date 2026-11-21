extends RefCounted
## OSC 99 assembly and validation, isolated per emitting terminal.
const MAX_TEXT := 64 * 1024
const MAX_ICON := 4 * 1024 * 1024
var partial: Dictionary = {}
var icons: Dictionary = {}
var serial := 0

static func identifier(value: String) -> bool:
	return not value.is_empty() and value.length() <= 256 and RegEx.create_from_string("^[a-zA-Z0-9_+.-]+$").search(value) != null

static func reply(id: String, kind: String, payload := "") -> String:
	return "\u001b]99;i=%s%s;%s\u001b\\" % [id if identifier(id) else "0", ":p=" + kind if not kind.is_empty() else "", payload]

static func decode64(value: String) -> PackedByteArray:
	if RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$").search(value) == null or value.length() % 4 == 1: return PackedByteArray()
	return Marshalls.base64_to_raw(value + "=".repeat((4 - value.length() % 4) % 4))

static func clean(value: String, multiline := false) -> String:
	var result := ""
	for c in value:
		if (multiline and c in ["\n", "\t"]) or c.unicode_at(0) >= 32 and (c.unicode_at(0) < 127 or c.unicode_at(0) > 159): result += c
	return result

func receive(packet: String) -> Dictionary:
	var separator := packet.find(";")
	if separator < 0: return {}
	var meta: Dictionary = {}
	for entry in packet.left(separator).split(":"):
		if entry.find("=") != 1: continue
		var key := entry.left(1)
		var value := entry.substr(2)
		if key in ["n", "t"]:
			if not meta.has(key): meta[key] = []
			meta[key].append(value)
		else: meta[key] = value
	var id: String = meta.get("i", "")
	if not id.is_empty() and not identifier(id): return {}
	var kind: String = meta.get("p", "title")
	if kind in ["?", "alive", "close"]:
		if kind == "close": partial.erase(id)
		return {"op": kind, "id": id}
	if kind not in ["title", "body", "buttons", "icon"]: return {}
	var payload := packet.substr(separator + 1)
	var encoded: bool = meta.get("e", "0") == "1"
	if kind == "icon" and not encoded: return {}
	if encoded and RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$").search(payload) == null:
		partial.erase(id)
		return {}
	if payload.to_utf8_buffer().size() > (4096 if encoded else 2048): return {}
	if not partial.has(id):
		if partial.size() >= 32: return {}
		partial[id] = {"id": id, "title": "", "body": "", "buttons": "", "icon": PackedByteArray(),
			"focus": true, "report": false, "close_report": false, "occasion": "always", "urgency": 1,
			"timeout": -1, "app_name": "", "types": [], "icon_names": [], "icon_id": "", "sound": "system", "buffers": {}, "raw": {}}
	var draft: Dictionary = partial[id]
	var buffers: Dictionary = draft.buffers
	var bytes := payload.to_utf8_buffer()
	if encoded:
		var pending: String = buffers.get(kind, "") + payload
		var complete := pending.length() - pending.length() % 4
		bytes = decode64(pending.left(complete)) if complete > 0 else PackedByteArray()
		buffers[kind] = pending.substr(complete)
	elif not str(buffers.get(kind, "")).is_empty():
		partial.erase(id)
		return {}
	var raw: PackedByteArray = draft.raw.get(kind, PackedByteArray())
	raw.append_array(bytes)
	if raw.size() > (MAX_ICON if kind == "icon" else MAX_TEXT):
		partial.erase(id)
		return {}
	draft.raw[kind] = raw
	if meta.has("a"):
		for action in str(meta.a).split(","):
			if action in ["focus", "report", "-focus", "-report"]: draft[action.trim_prefix("-")] = not action.begins_with("-")
	if meta.has("c"): draft.close_report = meta.c == "1"
	if meta.get("o", "") in ["always", "unfocused", "invisible"]: draft.occasion = meta.o
	if meta.get("u", "") in ["0", "1", "2"]: draft.urgency = int(meta.u)
	if meta.has("w") and str(meta.w).is_valid_int(): draft.timeout = maxi(-1, int(meta.w))
	for field in [["f", "app_name"], ["s", "sound"]]:
		if meta.has(field[0]): draft[field[1]] = clean(decode64(meta[field[0]]).get_string_from_utf8())
	for field in [["n", "icon_names"], ["t", "types"]]:
		for value in meta.get(field[0], []):
			var text := clean(decode64(value).get_string_from_utf8())
			if not text.is_empty() and draft[field[1]].size() < 32: draft[field[1]].append(text)
	if meta.has("g") and identifier(meta.g): draft.icon_id = meta.g
	if meta.get("d", "1") == "0": return {}
	partial.erase(id)
	for part in draft.raw:
		var tail: String = buffers.get(part, "")
		if tail.length() % 4 == 1: return {}
		var assembled: PackedByteArray = draft.raw[part]
		assembled.append_array(decode64(tail))
		draft.raw[part] = assembled
		if part == "icon": draft.icon = draft.raw[part]
		else: draft[part] = clean(draft.raw[part].get_string_from_utf8(), true)
	draft.erase("raw")
	draft.erase("buffers")
	if not draft.icon.is_empty() and not draft.icon_id.is_empty():
		if not icons.has(draft.icon_id) and icons.size() >= 16: icons.erase(icons.keys()[0])
		icons[draft.icon_id] = draft.icon
	elif icons.has(draft.icon_id): draft.icon = icons[draft.icon_id]
	if draft.title.is_empty():
		draft.title = draft.body
		draft.body = ""
	if draft.title.is_empty(): return {}
	draft.buttons = Array(str(draft.buttons).split("\u2028", false)).slice(0, 16)
	serial += 1
	draft["key"] = id if not id.is_empty() else "anonymous-%d" % serial
	draft["op"] = "show"
	return draft
