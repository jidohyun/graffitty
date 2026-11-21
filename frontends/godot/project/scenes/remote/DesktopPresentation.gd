extends RefCounted
## A hidden desktop presentation retains its transport, shells and navigation.
## Switching computers parks/restores views without disconnecting either server.
var client: Node
var window: Window
var parked := false
var connections: Array[Dictionary] = []
var process_mode: int
var disable_3d: bool
var connection_process_mode: int

func park(source: Node, retain_parent := false) -> void:
	if parked: return
	client = source
	parked = true
	var host: Node = client.host
	window = client.get_window()
	if is_instance_valid(host): host.workspace_view.save_navigation()
	for signal_info in window.get_signal_list():
		for entry in window.get_signal_connection_list(signal_info.name):
			# CanvasItem/Control retarget their own native hooks on reparent.
			if entry.callable.get_method().is_empty() or "::" in entry.callable.get_method(): continue
			var object: Object = entry.callable.get_object()
			if object is Node and (object == client or client.is_ancestor_of(object)):
				connections.append({"signal":signal_info.name,"callable":entry.callable,"flags":entry.flags})
				window.disconnect(signal_info.name, entry.callable)
	if is_instance_valid(host):
		host._remove_menu()
		host.application.hosts.erase(host)
	process_mode = client.process_mode
	connection_process_mode = client.connection.process_mode
	client.applying = true
	# Keep the transport and owner heartbeat alive while its view is parked.
	client.connection.process_mode = Node.PROCESS_MODE_ALWAYS
	client.dialog.hide()
	client.process_mode = Node.PROCESS_MODE_DISABLED
	if is_instance_valid(host):
		disable_3d = host.world_viewport.disable_3d
		host.layout_root.hide()
		host.moving_window = true
		host.world_viewport.set_block_signals(true)
	client.moving_presentation = true
	if not retain_parent: client.reparent(client.get_node("/root/TerminalApplication"))
	client.moving_presentation = false
	if is_instance_valid(host):
		host.world_viewport.set_block_signals(false)
		host.world_viewport.disable_3d = true
		host.moving_window = false

func restore(target: Window) -> bool:
	if not parked or not is_instance_valid(client): return false
	var saved: Node = client
	parked = false
	window = target
	var host: Node = saved.host
	if is_instance_valid(host):
		host.moving_window = true
		host.world_viewport.set_block_signals(true)
	saved.moving_presentation = true
	if saved.get_parent() != window: saved.reparent(window)
	saved.moving_presentation = false
	if is_instance_valid(host):
		host.world_viewport.set_block_signals(false)
		host.world_viewport.disable_3d = disable_3d
		host.moving_window = false
	for entry in connections:
		if entry.callable.is_valid() and not window.is_connected(entry.signal, entry.callable):
			window.connect(entry.signal, entry.callable, entry.flags)
	connections.clear()
	saved.process_mode = process_mode
	saved.connection.process_mode = connection_process_mode
	saved.applying = false
	if is_instance_valid(host):
		host.application.hosts.append(host)
		host.layout_root.show()
		host._refresh_workspace_layout()
		host._build_menu.call_deferred()
	saved._refresh.call_deferred()
	window.title = "Graffitty"
	window.show()
	window.grab_focus()
	return true
