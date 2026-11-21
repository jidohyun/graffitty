extends SceneTree
## Run with Godot --headless --path . --script tools/build_packs.gd.
## Builds the host pack. Each world repository builds its own pack.
var packed := { }
var packer: PCKPacker
var failed := false


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://dist")
	# res://dist is the repository's generated /dist. Keep the editor from
	# importing the packs and binaries written there.
	if not FileAccess.file_exists("res://dist/.gdignore"):
		FileAccess.open("res://dist/.gdignore", FileAccess.WRITE).close()
	var version_output: Array = []
	if OS.execute(
		"uv",
		["run", ProjectSettings.globalize_path("res://tools/build_info.py")],
		version_output,
		true,
	) != 0:
		push_error("Build version generation failed: " + str(version_output))
		quit(1)
		return
	var cli_build_output: Array = []
	if OS.execute(
		"mise",
		["--cd", ProjectSettings.globalize_path("res://"), "run", "core:build"],
		cli_build_output,
		true,
	) != 0:
		push_error("CLI build failed: " + str(cli_build_output))
		quit(1)
		return
	packer = PCKPacker.new()
	check(packer.pck_start("res://dist/terminal.pck"))
	check(packer.add_file("res://project.godot", "res://project.godot"))
	add_tree("res://graffitty")
	add_tree("res://config")
	add_tree("res://assets/branding/exports")
	# Scene dependencies evolve together. Include the complete runtime tree so
	# a new helper cannot work in development and disappear from releases.
	add_tree("res://scenes")
	# PaneIcons reads raw bytes to create cached textures without import remaps.
	add_tree("res://assets/icons")
	# Icon providers load source files directly, including after editor import.
	add_icon_sources("res://assets/icons")
	add_icon_sources("res://scenes/icons")
	add_tree("res://presets")
	# Bundled panels: their scripts and manifests, and the raw SVG icons the
	# panel view rasterizes itself (add_tree keeps only imported resources).
	add_tree("res://mods")
	add_icon_sources("res://mods/icons")
	add_file("res://addons/graffitty/graffitty.gdextension")
	add_file("res://.godot/extension_list.cfg")
	add_file("res://.godot/global_script_class_cache.cfg")
	check(packer.flush())
	# Native extensions must remain loose beside the application pack.
	# Agent CLI and its guide are executables/resources for external processes.
	DirAccess.make_dir_recursive_absolute("res://dist/tools")
	check(
		DirAccess.copy_absolute(
			"res://../../../tools/install_shell_integration.py",
			"res://dist/tools/install_shell_integration.py",
		)
	)
	DirAccess.make_dir_recursive_absolute("res://dist/tools/shell-integration")
	var shell_integration := ProjectSettings.globalize_path("res://../../../apps/server/shell-integration")
	for name in DirAccess.get_files_at(shell_integration):
		check(
			DirAccess.copy_absolute(
				shell_integration.path_join(name),
				"res://dist/tools/shell-integration/" + name,
			)
		)
	DirAccess.make_dir_recursive_absolute("res://dist/skills/terminal-chromium")
	DirAccess.make_dir_recursive_absolute("res://dist/skills/graffitty")
	check(DirAccess.copy_absolute("res://skills/graffitty/SKILL.md", "res://dist/skills/graffitty/SKILL.md"))
	check(DirAccess.copy_absolute("res://../../../dist/bin/gft", "res://dist/tools/gft", 493))
	# gft-gui is gft under another name, never a second copy of it.
	var tools := DirAccess.open("res://dist/tools")
	tools.remove("gft-gui")
	check(tools.create_link("gft", "gft-gui"))
	check(
		DirAccess.copy_absolute(
			"res://skills/terminal-chromium/SKILL.md",
			"res://dist/skills/terminal-chromium/SKILL.md",
		)
	)
	DirAccess.make_dir_recursive_absolute("res://dist/addons/graffitty/bin")
	for name in DirAccess.get_files_at("res://addons/graffitty/bin"):
		if name.ends_with(".dylib") or name.ends_with(".so") or name.ends_with(".dll"):
			check(
				DirAccess.copy_absolute(
					"res://addons/graffitty/bin/" + name,
					"res://dist/addons/graffitty/bin/" + name,
				)
			)
	print("[pack] host: %d files; excludes worlds and world assets" % packed.size())
	quit(1 if failed else 0)


func check(error: Error) -> void:
	if error != OK:
		push_error("Pack operation failed: %s" % error_string(error))
		failed = true


func add_file(path: String) -> void:
	if packed.has(path):
		return
	packed[path] = true
	check(packer.add_file(path, path))


func add_tree(path: String) -> void:
	# Raw source archives are authoring inputs, never runtime pack contents.
	if FileAccess.file_exists(path.path_join(".gdignore")):
		return
	for name in DirAccess.get_directories_at(path):
		if not name.begins_with("."):
			add_tree(path.path_join(name))
	for name in DirAccess.get_files_at(path):
		var file := path.path_join(name)
		if name.ends_with(".uid"):
			continue
		if name.ends_with(".import"):
			# Keep remaps and their imported GPU resources, not source PNG/GLB.
			add_file(file)
			var cfg := ConfigFile.new()
			check(cfg.load(file))
			for dest in cfg.get_value("deps", "dest_files", PackedStringArray()):
				add_file(dest)
		elif not FileAccess.file_exists(file + ".import"):
			add_file(file)


func add_icon_sources(path: String) -> void:
	for name in DirAccess.get_directories_at(path):
		if not name.begins_with("."):
			add_icon_sources(path.path_join(name))
	for name in DirAccess.get_files_at(path):
		if name.get_extension() in ["svg", "png"]:
			add_file(path.path_join(name))
