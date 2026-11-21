extends RefCounted
## Embedded UI keeps native focus/IME and gesture routing; mods paint content.
static func create(name: String, props: Dictionary) -> Control:
 var host: RefCounted = ClassDB.instantiate("ModHost")
 var error: String = host.setup(preload("res://graffitty/paths.gd").stdpath("state"))
 if not error.is_empty(): push_error(error)
 var view: Control = ClassDB.instantiate("ModView")
 view.mouse_filter = Control.MOUSE_FILTER_IGNORE
 var spec := preload("res://scenes/mods/ModService.gd").manifest(name)
 if not spec.get("enabled", false): return view
 error = preload("res://scenes/mods/ModService.gd").load_registered(view, name, props)
 view.set_meta(&"mod_name", name)
 if not error.is_empty(): push_error(error)
 return view

static func set_props(view: Control, props: Dictionary) -> void:
 var name: String = view.get_meta(&"mod_name", "")
 view.set_props(JSON.stringify(preload("res://scenes/mods/ModService.gd").mod_props(name, props)))
