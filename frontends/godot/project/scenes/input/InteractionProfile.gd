extends RefCounted
## Explicit desktop test opt-in runs touch controls without faking the OS.
static func touch_controls() -> bool:
	return OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch-controls") or OS.get_environment("GRAFFITTY_TOUCH_CONTROLS") == "1"
