extends SceneTree
const Browser := preload("res://scenes/remote/ServerBrowserPage.gd")
const Desktop := preload("res://scenes/remote/DesktopServers.gd")
const Card := preload("res://scenes/remote/ServerCard.gd")
class App extends Node:
	var show_servers_at_startup := false
	func set_show_servers_at_startup(value: bool) -> void: show_servers_at_startup = value
class Connection extends Node:
	signal state_changed(message: String)
	signal changed
	signal authenticated
	var connected := true
	var enabled := true
	var status_source := "Connected"
	var status_args: Array = []
class Client extends Node:
	var settings := {"shared_local": true}
	var connection := Connection.new()
	var local_return: RefCounted
	var host: Node
	func _init() -> void: add_child(connection)
var errors := preload("res://tests/run.gd").ErrorCapture.new()
var failures: Array[String] = []
func _initialize() -> void:
	var directory := OS.get_cache_dir().path_join("gft-browser-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	OS.add_logger(errors)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func settle() -> void:
	await create_timer(.1).timeout
func run() -> void:
	root.gui_embed_subwindows = true
	root.size = Vector2i(1100, 800)
	var app := App.new()
	root.add_child(app)
	var client := Client.new()
	root.add_child(client)
	var desktop := Desktop.new()
	desktop.application = app
	root.add_child(desktop)
	desktop.present(client)
	await settle()
	check(desktop.chooser is Browser, "Desktop uses shared Android browser")
	for width in [840, 390, 320]:
		desktop.size = Vector2i(width, 620)
		await settle()
		check(desktop.chooser.size.x <= width, "Browser fits width %d" % width)
		check(desktop.chooser.add_server.is_visible_in_tree(), "Add server visible at width %d" % width)
		desktop.chooser.add_server.pressed.emit()
		await settle()
		check(desktop.form.visible and not desktop.chooser.visible, "Add uses separate Android-style editor page")
		check(desktop.editor.is_visible_in_tree(), "Shared editor is visible")
		desktop.editor.token.text = "unsubmitted-fixture"
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		desktop.push_input(escape, true)
		check(desktop.chooser.visible and not desktop.form.visible and desktop.editor.token.text.is_empty(), "Back returns to cards and clears unsubmitted secret")
	var card := Card.new()
	desktop.chooser.rows.add_child(card)
	card.update_identity({"url": "ws://example.invalid:7183", "name": "Fixture"})
	await settle()
	check(card.size.x <= desktop.chooser.available_content_width(), "Shared server card fits narrow layout")
	var close := InputEventKey.new()
	close.keycode = KEY_ESCAPE
	close.pressed = true
	desktop.push_input(close, true)
	check(not desktop.visible and client.connection.connected, "Closing manager preserves client connection")
	desktop.queue_free()
	client.queue_free()
	app.queue_free()
	await settle()
	failures.append_array(errors.take())
	OS.remove_logger(errors)
	print("SERVER_BROWSER_PASS" if failures.is_empty() else "SERVER_BROWSER_FAIL " + str(failures))
	quit(0 if failures.is_empty() else 1)
