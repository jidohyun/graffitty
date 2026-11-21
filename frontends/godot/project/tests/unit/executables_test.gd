extends "res://tests/unit/test_case.gd"
## The CLI's output reaches the app as its UTF-8 bytes, whatever the system code page.
const Executables := preload("res://graffitty/executables.gd")

func test_cli_output_decodes_as_utf8_and_drains_both_pipes() -> void:
	var previous := OS.get_environment("GRAFFITTY_BIN")
	# More stderr than a pipe holds must not stall reading stdout.
	var args: PackedStringArray
	if OS.get_name() == "Windows":
		OS.set_environment("GRAFFITTY_BIN", "powershell.exe")
		# Godot does not escape quotes inside Windows arguments; build them here.
		args = ["-NoLogo", "-NoProfile", "-Command", "$q = [char]34; $o = [Console]::OpenStandardOutput(); $b = [Text.Encoding]::UTF8.GetBytes('{' + $q + 't' + $q + ':' + $q + '한글 Ω ❯' + $q + '}'); [Console]::Error.Write('x' * 200000); $o.Write($b, 0, $b.Length); exit 3"]
	else:
		OS.set_environment("GRAFFITTY_BIN", "/bin/sh")
		args = ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; printf '{\"t\":\"한글 Ω ❯\"}'; exit 3"]
	var result := Executables.run_cli(args)
	if previous.is_empty(): OS.unset_environment("GRAFFITTY_BIN")
	else: OS.set_environment("GRAFFITTY_BIN", previous)
	expect(result.code == 3, "The CLI's exit code is reported")
	expect(result.output == "{\"t\":\"한글 Ω ❯\"}", "Non-ASCII JSON survives intact: " + str(result.output))
	expect(str(result.errors).length() == 200000, "Stderr is read in full alongside stdout")


func test_a_versioned_installation_is_addressed_through_its_current_link() -> void:
	if OS.get_name() == "Windows": return
	var root := OS.get_cache_dir().path_join("graffitty-executables-test-%d" % OS.get_process_id())
	for version in ["0.1.0", "0.2.0"]:
		DirAccess.make_dir_recursive_absolute(root.path_join(version).path_join("tools"))
		FileAccess.open(root.path_join(version).path_join("tools/gft"), FileAccess.WRITE).close()
	var installs := DirAccess.open(root)
	expect(installs.create_link("0.2.0", root.path_join("current")) == OK, "The fixture links the current version")
	# An older version's path maps to `current` too: its next launch is the new version.
	for version in ["0.1.0", "0.2.0"]:
		expect(Executables.installed(root.path_join(version).path_join("tools/gft")) == root.path_join("current/tools/gft"),
			"Version %s is addressed through the current link" % version)
	installs.remove("current")
	expect(Executables.installed(root.path_join("0.2.0/tools/gft")) == root.path_join("0.2.0/tools/gft"),
		"An installation replaced in place keeps its own path")
	for version in ["0.1.0", "0.2.0"]:
		DirAccess.remove_absolute(root.path_join(version).path_join("tools/gft"))
		DirAccess.remove_absolute(root.path_join(version).path_join("tools"))
		DirAccess.remove_absolute(root.path_join(version))
	DirAccess.remove_absolute(root)
	expect(not DirAccess.dir_exists_absolute(root), "The fixture is removed")
