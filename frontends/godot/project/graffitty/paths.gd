extends RefCounted
## Public XDG-aware paths for user configuration and installed assets.


static func expand_home(path: String) -> String:
	var home_dir := OS.get_environment("HOME")
	if home_dir.is_empty():
		home_dir = OS.get_environment("USERPROFILE")
	if path == "~":
		return home_dir
	if path.begins_with("~/"):
		return home_dir.path_join(path.substr(2))
	return path


## The directory the app was launched from. The `gft-gui` launcher passes it
## in GRAFFITTY_INITIAL_PWD.
##
## Process cwd is not the caller's directory in exported builds, so a direct
## launch (a shortcut or the installer) uses home.
static func launch_directory() -> String:
	var initial := OS.get_environment("GRAFFITTY_INITIAL_PWD")
	if not initial.is_empty():
		return initial
	if OS.has_feature("template"):
		var home := expand_home("~")
		if not home.is_empty():
			return home
	return DirAccess.open(".").get_current_dir()


static func directory(variable: String, fallback: String) -> String:
	var base := OS.get_environment(variable)
	if base.is_empty() or not base.is_absolute_path():
		base = expand_home(fallback)
	return base.path_join("graffitty")


## Return an application directory without creating it. Absolute XDG overrides
## take precedence; empty or relative values use the documented home defaults.
static func stdpath(kind: String) -> String:
	if OS.has_feature("mobile") and kind in ["config", "data", "cache", "state"]:
		return ProjectSettings.globalize_path("user://").path_join(kind)
	match kind:
		"config":
			return directory("XDG_CONFIG_HOME", "~/.config")
		"data":
			return directory("XDG_DATA_HOME", "~/.local/share")
		"cache":
			return directory("XDG_CACHE_HOME", "~/.cache")
		"state":
			return directory("XDG_STATE_HOME", "~/.local/state")
	push_error("Unknown stdpath kind '%s'; expected config, data, cache, or state" % kind)
	return ""


## The automatic client configuration file.
static func config_path() -> String:
	return stdpath("config").path_join("client.toml")


static func data_directory() -> String:
	return stdpath("data")
