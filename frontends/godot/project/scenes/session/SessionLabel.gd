extends RefCounted
## Labels never act as identity; all selection and mutation targets use id.
static func name_of(session: Dictionary) -> String:
	var manual: Variant = session.get("name")
	if manual is String and not manual.is_empty(): return manual
	var automatic: Variant = session.get("automatic_name")
	return automatic if automatic is String else ""

static func display(session: Dictionary) -> String:
	var label := name_of(session)
	return str(session.id) if label.is_empty() else label + "  " + str(session.id)
