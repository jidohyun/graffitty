extends RefCounted
## Explicit launch options only; all spawn defaults belong to the server.
static func options(args: PackedStringArray, launch_directory := "") -> Dictionary:
	var result := {}
	for i in args.size():
		var arg := args[i]
		if arg.begins_with("--shell="):
			result.shell = arg.trim_prefix("--shell=")
			result.login = false
		elif arg.begins_with("--cwd="): result.cwd = arg.trim_prefix("--cwd=")
		elif arg == "--cwd" and i + 1 < args.size(): result.cwd = args[i + 1]
		elif arg.begins_with("--working-directory="): result.cwd = arg.trim_prefix("--working-directory=")
		elif arg.begins_with("--storage="): result.kitty_image_storage_mb = int(arg.trim_prefix("--storage="))
		elif arg.begins_with("--apc="): result.kitty_image_transmission_mib = int(arg.trim_prefix("--apc="))
	var initial: String = launch_directory if not launch_directory.is_empty() else preload("res://graffitty/paths.gd").launch_directory()
	if result.has("cwd"):
		result.cwd = preload("res://config/UserConfig.gd").expand_home(str(result.cwd))
		if not str(result.cwd).is_absolute_path():
			result.cwd = initial.path_join(str(result.cwd)).simplify_path()
	else: result.cwd = initial
	return result
