extends "res://tests/mods_fixture.gd"
## The Sessions window renders the Sessions mod from published servers and
## switches sessions through the owning peer. No real servers.
const Fixture := preload("res://tests/unit/sessions_test.gd")
const SessionDrag := preload("res://scenes/session/SessionPanelDrag.gd")
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")

func check_drop_targets(dialog: Window, peer: Node, label: String) -> void:
	var row: Rect2 = dialog.view.hit_rect("session-%s-$2" % peer.url)
	var found := SessionDrag.hit(app, ScreenSpace.of(dialog.view, row.get_center()), app.hosts[0])
	check(found.get("session") == "$2" and found.get("server") == peer.url, label + " session row accepts a transfer")
	var plus: Rect2 = dialog.view.hit_rect("new-%s" % peer.url)
	# Compact sidebars omit the header; blank list space is their new-session target.
	var point: Vector2 = plus.get_center() if plus.has_area() else dialog.view.hit_rect("list").end - Vector2(2, 2)
	found = SessionDrag.hit(app, ScreenSpace.of(dialog.view, point), app.hosts[0])
	check(found.get("session") == "" and found.get("server") == peer.url, label + " new-session target accepts a drop: " + str(found))

class Peer extends Fixture.Peer:
	signal changed
	var switched := ""
	var created := 0
	func request_action(action: String, params: Dictionary) -> Dictionary:
		if action == "session_new":
			created += 1
			return {"type": "ack"}
		assert(action == "session_switch")
		switched = params.name
		workspace = params.name
		return {"type": "ack"}

class Client extends Node:
	var federated := false

class SessionHost extends Fixture.Host:
	var server_chooser := Callable()
	var active_session_id := 1
	var application: Node
	func active_terminal() -> Node: return null

func run() -> void:
	setup()
	var client := Client.new()
	root.add_child(client)
	var session_host := SessionHost.new()
	session_host.application = app
	client.add_child(session_host)
	var peer := Peer.new()
	root.add_child(peer)
	peer.available_sessions = [
		{"id": "$1", "name": "first"}, {"id": "$2", "name": "second"},
		{"id": "$3", "name": "third"}, {"id": "$4", "name": "fourth"}]
	session_host.session_backend.connection = peer
	var manager_opened := [false]
	host.server_chooser = func(): manager_opened[0] = true
	app.hosts = [session_host]
	app.mods._publish_sessions()
	var dialog: Window = PanelWindow.open(host, "sessions")
	await settle()
	check(is_instance_valid(dialog._desktop) and dialog._desktop.side == "left" and not dialog.visible, "Sessions docks into the left sidebar by default")
	check_drop_targets(dialog, peer, "Docked")
	# The rest exercises the floating window, as a title double-click leaves it.
	dialog.float_native()
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Sessions mod loads and renders: " + dialog.view.last_error())
	check(dialog._available().encloses(Rect2i(dialog.position, dialog.size)), "Window fits the screen")
	check_drop_targets(dialog, peer, "Floating")
	var shown := texts(dialog)
	check("Remote fixture" in shown and "first" in shown and "fourth" in shown and "$2" in shown, "Server header, names and ids are drawn: %s" % [shown])
	check(not dialog.exclusive and not dialog.unresizable, "Non-modal and resizable")
	check("add-server" in dialog.view.hit_keys() and "+ Add server" in shown, "Desktop offers Add server")
	dialog.view.click("add-server")
	pump()
	check(manager_opened[0], "Add server invokes the normal workspace manager")
	dialog.view.click("session-%s-$2" % peer.url)
	pump()
	await settle()
	check(peer.switched == "$2", "Selection uses session_switch on the owning peer")
	check(dialog.visible, "Switching leaves the non-modal list open")
	dialog.view.click("new-%s" % peer.url)
	pump()
	await settle()
	check(peer.created == 1, "The header's + creates a session on that server")
	dialog.view.click("server-%s" % peer.url)
	await settle()
	check(not "first" in texts(dialog) and "Remote fixture" in texts(dialog), "Clicking the header folds its sessions")
	dialog.view.click("server-%s" % peer.url)
	await settle()
	check("first" in texts(dialog), "Clicking again unfolds")
	var saved := {"url": "wss://saved.example", "name": "Saved fixture"}
	var save_error := preload("res://scenes/remote/ClientAuthentication.gd").save_connection(saved)
	await settle()
	check(save_error.is_empty() and has_text(dialog, "Saved fixture"), "Saving a connection immediately refreshes the Sessions mod")
	peer.connected = false
	peer.changed.emit()
	await settle()
	check(("connect-%s" % peer.url) in dialog.view.hit_keys() and "Connect" in texts(dialog) and not "first" in texts(dialog), "Disconnected servers offer Connect instead of stale sessions")
	peer.connected = true
	peer.changed.emit()
	dialog.set_compact(true)
	await settle()
	shown = texts(dialog)
	check("1" in shown and "4" in shown and not "first" in shown and not "add-server" in dialog.view.hit_keys(), "Compact rows show real session IDs and no footer action: %s" % [shown])
	dialog.set_compact(false)
	await settle()
	var rect := Rect2i(dialog.position, dialog.size)
	dialog.set_bottom_inset(260)
	await process_frame
	check(dialog.title_reachable() and dialog.position.y + int(dialog.floating_title_height()) <= dialog._available().end.y, "Keyboard inset keeps the title reachable above the keyboard")
	dialog.set_bottom_inset(0)
	await process_frame
	check(Rect2i(dialog.position, dialog.size) == rect, "Removing the inset restores geometry")
	dialog.queue_free()
	await settle()
	finish("SESSIONS_DIALOG")
