extends "res://tests/unit/test_case.gd"
const Config := preload("res://graffitty/terminal_config.gd")
const Spawn := preload("res://scenes/session/SpawnPreferences.gd")
func test_launcher_directory_takes_precedence() -> void:
 var previous := OS.get_environment("GRAFFITTY_INITIAL_PWD")
 OS.set_environment("GRAFFITTY_INITIAL_PWD", "/launched/here")
 expect(Spawn.options(PackedStringArray()).get("cwd") == "/launched/here", "gft-gui's launch directory starts the first terminal")
 if previous.is_empty(): OS.unset_environment("GRAFFITTY_INITIAL_PWD")
 else: OS.set_environment("GRAFFITTY_INITIAL_PWD", previous)
 expect(not Spawn.options(PackedStringArray()).get("cwd", "").is_empty(), "A direct launch still starts in a directory")
func test_frontend_only_sends_explicit_spawn_options() -> void:
 var request := Spawn.options(PackedStringArray(), "/tmp")
 expect(request == {"cwd":"/tmp"}, "No frontend shell or limit defaults are sent")
 request = Spawn.options(PackedStringArray(["--shell=/bin/sh", "--apc=12", "--cwd=subdir"]), "/tmp")
 expect(request.get("login") == false and request.get("kitty_image_transmission_mib") == 12, "Explicit launch options override server defaults")
 expect(request.get("cwd") == "/tmp/subdir", "Launch directory resolves explicit relative cwd")
 var config: ConfigFile = Config.new().copy().to_config()
 for key in ["shell", "login_shell", "environment", "working_directory", "shell_integration", "scrollback", "kitty_apc_max_mb", "kitty_image_storage_mb"]:
  expect(not config.has_section_key("terminal", key), "Frontend configuration excludes server option " + key)
