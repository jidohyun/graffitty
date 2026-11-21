extends "../../../../replay/replay.gd"

class FakePower extends "res://scenes/PowerMonitor.gd":
	func _ready() -> void:
		_accept({"available": true, "on_battery": true})


func _initialize() -> void:
	super._initialize()
	var path := preload("res://graffitty/paths.gd").config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string('[power]\nenabled = true\nbattery_world = "flat-2d"\nexternal_world = "flat-3d"\n')
	file.close()


func _start() -> void:
	var application := root.get_node("TerminalApplication")
	application._power_monitor = FakePower.new()
	application.add_child(application._power_monitor)
	await super._start()


func play() -> void:
	check(host.current_plugin == "flat-2d", "Battery selects Flat 2D at startup")
	await labelled_tabs(["POWER"])
	var id: int = int(host.pane_focus.substr(1))
	var pid: int = host.sessions[id].term.get_shell_pid()
	host.power._accept({"available": true, "on_battery": false})
	await hold(.3)
	check(host.current_plugin == "flat-3d", "External power selects Flat 3D")
	host.power._accept({"available": true, "on_battery": true})
	await hold(.3)
	check(host.current_plugin == "flat-2d", "Battery event selects Flat 2D")
	host.switch_world("")
	host.power._accept({"available": true, "on_battery": true})
	await hold(.3)
	check(host.current_plugin == "flat-3d", "Repeated snapshots preserve manual selection")
	host.power._accept({"available": false})
	await hold(.3)
	check(host.current_plugin == "flat-3d", "Unknown source preserves selected world")
	host.power._accept({"available": true, "on_battery": true})
	await hold(.3)
	check(host.current_plugin == "flat-2d", "Recovered state reapplies policy")
	check(pid > 0 and host.sessions[id].term.get_shell_pid() == pid, "Switching preserves running shell")
	var window := Window.new()
	app.add_child(window)
	var second: Node = load("res://scenes/TerminalHost.gd").new()
	window.add_child(second)
	check(second.power == host.power, "Windows share one power monitor")
	check(second.current_plugin == "flat-2d", "New windows use current power state")
	host.power._accept({"available": true, "on_battery": false})
	await hold(.3)
	check(second.current_plugin == "flat-3d" and host.current_plugin == "flat-3d", "Power changes update all windows")
	window.queue_free()
	await hold(.3)
	host.power._accept({"available": true, "on_battery": true})
	await hold(.3)
	check(host.current_plugin == "flat-2d", "Closing a window safely disconnects its listener")
	var startup_window := Window.new()
	app.add_child(startup_window)
	var startup_only: Node = load("res://scenes/TerminalHost.gd").new()
	startup_only.power_settings.follow_changes = false
	startup_window.add_child(startup_only)
	check(startup_only.current_plugin == "flat-2d", "Startup-only window selects battery world")
	host.power._accept({"available": true, "on_battery": false})
	await hold(.3)
	check(startup_only.current_plugin == "flat-2d" and host.current_plugin == "flat-3d", "Startup-only window ignores later power changes")
	startup_window.queue_free()
