extends RefCounted
## Profiles use the oriented physical mobile display size, not the viewport or
## IME area. Cover/inner screens each have independent portrait and landscape
## layouts.
##
## The unqualified file is the default layout used to initialize each new
## size.

static func key(size: Vector2i) -> String:
	if size.x <= 0 or size.y <= 0: return ""
	return "%dx%d" % [size.x, size.y]

static func path(base: String, size: Vector2i) -> String:
	var profile := key(size)
	return base if profile.is_empty() else base + ".display-" + profile

static func load_profile(base: String, size: Vector2i) -> ConfigFile:
	var config := ConfigFile.new()
	var target := path(base, size)
	if config.load(target) != OK and target != base:
		config.load(base)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		config.save(target)
	return config
