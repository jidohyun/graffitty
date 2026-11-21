extends PopupMenu
## The row's server and stable session ID stay fixed while its menu is open.
const Icons := preload("res://scenes/PaneIcons.gd")
const Chrome := preload("res://scenes/PopupChrome.gd")
enum Action { RENAME, KILL }
var host: Node
var peer: Node
var target := ""
var label := ""
var panel_view: Control
var row_key := ""

func _init() -> void:
	name = "SessionContextMenu"
	prefer_native_menu = false
	id_pressed.connect(_activate.call_deferred)

static func open(owner: Node, source: Node, transport: Node, session: String, session_name: String, view: Control = null, key := "") -> PopupMenu:
	var menu: PopupMenu = owner.get_node_or_null("SessionContextMenu")
	if menu == null:
		menu = load("res://scenes/session/SessionContextMenu.gd").new()
		owner.add_child(menu)
	else: Chrome.close(menu)
	menu.host = source
	menu.peer = transport
	menu.target = session
	menu.label = session_name if not session_name.is_empty() else session
	menu.panel_view = view
	menu.row_key = key
	menu.refresh()
	preload("res://scenes/input/PointerPopup.gd").open(menu)
	return menu

func refresh() -> void:
	clear()
	add_item(tr("Rename Session…"), Action.RENAME)
	add_separator()
	add_icon_item(Icons.trash(), tr("Kill Session"), Action.KILL)
	Chrome.mark_danger(self, get_item_index(Action.KILL))
	var available: bool = is_instance_valid(peer) and peer.connected
	set_item_disabled(get_item_index(Action.RENAME), not available)
	set_item_disabled(get_item_index(Action.KILL), not available)

func _activate(action: int) -> void:
	if not is_instance_valid(host) or not is_instance_valid(peer) or not peer.connected: return
	match action:
		Action.RENAME:
			if is_instance_valid(panel_view):
				var edit := preload("res://scenes/session/SessionNameEdit.gd").new()
				edit.peer = peer
				edit.target = target
				edit.row_key = row_key
				for session in peer.available_sessions:
					if session.id == target and session.name is String: edit.text = session.name
				panel_view.add_child(edit)
			else:
				preload("res://scenes/session/LiveSessionMenu.gd").rename(host, peer, target)
		Action.KILL:
			preload("res://scenes/session/KillSessionDialog.gd").open(get_parent().get_window(), peer, target, label)
