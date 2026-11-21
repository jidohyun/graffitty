extends "res://tests/unit/test_case.gd"
const Manager := preload("res://scenes/remote/RemoteManager.gd")

class Host extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var workspace_view: Control
	var layout_root := Control.new()
	func select_workspace(id: int, _instant: bool) -> void: workspace_layout.active = id

class View extends Node:
	var host: Node

class BackManager extends "res://scenes/remote/RemoteManager.gd":
	var chooser_calls := 0
	func _remember_view() -> void: pass
	func _show_chooser() -> void:
		chooser_calls += 1
		_set_workspace_visible(false)
		chooser.show()

func test_back_dismisses_workspace_menus_before_navigation() -> void:
	var manager := BackManager.new()
	manager.view = View.new()
	manager.view.host = Host.new()
	manager.view.host.add_child(manager.view.host.layout_root)
	var menu := preload("res://scenes/input/MobileMenu.gd").new()
	manager.view.host.add_child(menu)
	var context := PopupMenu.new()
	manager.view.host.add_child(context)
	var submenu := PopupMenu.new()
	context.add_child(submenu)
	manager.dialog.hide()
	manager.chooser.hide()
	menu.set_expanded(true, false)
	context.show()
	submenu.show()
	manager._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	expect(not context.visible and not submenu.visible and not menu.expanded, "Back closes popup, submenu and expanded menu chrome")
	expect(manager.chooser_calls == 0 and not manager.chooser.visible and manager.view.host.layout_root.visible, "That Back does not leave the workspace")
	manager._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	expect(manager.chooser_calls == 1 and manager.chooser.visible, "A subsequent Back may open the manager")
	# Direct navigation must also clean up windows outside the layout Control.
	context.show()
	submenu.show()
	menu.set_expanded(true, false)
	manager._set_workspace_visible(false)
	expect(not context.visible and not submenu.visible and not menu.expanded, "Workspace manager and workspace menus cannot coexist")
	manager.view.host.free()
	manager.view.free()
	manager.federation.free()
	manager.free()

func test_server_page_controls_pass_scroll_gestures() -> void:
	var page := Manager.Page.new()
	var gesture := preload("res://scenes/input/TouchScrollGesture.gd").new(page, page.scroll)
	var card := PanelContainer.new()
	var button := Button.new()
	page.scroll.add_child(card)
	card.add_child(button)
	gesture._allow_scroll_gestures(card)
	gesture._allow_scroll_gestures(button)
	expect(card.mouse_filter == Control.MOUSE_FILTER_PASS, "Card backgrounds let drags reach the scroll container")
	expect(button.mouse_filter == Control.MOUSE_FILTER_PASS, "Buttons let native scrolling cancel presses and retain inertia")
	var footer := Button.new()
	page.add_child(footer)
	gesture._allow_scroll_gestures(footer)
	expect(footer.mouse_filter == Control.MOUSE_FILTER_STOP, "Fixed footer buttons are unaffected")
	var scrollbar := page.scroll.get_v_scroll_bar()
	gesture._allow_scroll_gestures(scrollbar)
	expect(scrollbar.mouse_filter == Control.MOUSE_FILTER_STOP, "Scrollbar keeps its own drag interaction")
	gesture.free()
	page.free()

func test_connection_page_reserves_vertical_scrollbar_width() -> void:
	var page := Manager.Page.new()
	page.max_content_width = 1000.0
	page.scroll.size.x = 750
	var scrollbar := page.scroll.get_v_scroll_bar()
	scrollbar.show()
	page._resize_content()
	expect(is_equal_approx(page.content.custom_minimum_size.x, 710 - scrollbar.get_combined_minimum_size().x), "Content and margins fit beside the vertical scrollbar")
	scrollbar.hide()
	page._resize_content()
	expect(is_equal_approx(page.content.custom_minimum_size.x, 710), "No scrollbar leaves the full available width")
	page.free()

func test_server_list_uses_full_width_compact_rows() -> void:
	var manager := Manager.new()
	expect(manager.rows is VBoxContainer, "Servers use a single device list, not wide multi-action cards")
	manager._remember_entry(settings(), "disconnected", "Ready to connect")
	var card: PanelContainer = manager.cards.values()[0]
	expect(card.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "Cards fill the list width")
	manager.federation.free()
	manager.free()

func test_reopening_connected_server_keeps_selected_tab() -> void:
	var manager := remembered_manager()
	var input := settings()
	var key: String = manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	transport.connected = true
	transport.workspace = "$1"
	transport.topology = {"tabs": [{"id": 10}, {"id": 20}], "panes": []}
	manager.view = View.new()
	manager.view.host = Host.new()
	manager.view.host.workspace_layout.active = 20
	manager.dialog.hide()
	manager._open_workspace(key)
	expect(manager.view.host.workspace_layout.active == 20, "Returning from offline/server chooser keeps the selected tab instead of opening tab one")
	manager.view.host.workspace_layout.active = 999
	manager._open_workspace(key)
	expect(manager.view.host.workspace_layout.active == 10, "A removed tab falls back to a valid tab")
	manager.view.host.free()
	manager.view.free()
	manager.federation.free()
	manager.free()

class FlightWorld extends RefCounted:
	var flights := 0
	func begin_session_transition() -> void: pass
	func finish_session_transition() -> void: flights += 1

class FlightHost extends Host:
	var world := FlightWorld.new()
	var session_switch_in_progress := false
	var landed: Array = []
	func select_workspace(id: int, _instant: bool) -> void:
		workspace_layout.active = id
		landed.append(workspace_layout.tab(id).focused)
	func reveal_pane(key: String) -> void:
		var group: int = workspace_layout.containing(key)
		if group != workspace_layout.active: landed.append("tab switch")
		workspace_layout.active = group
		workspace_layout.tab(group).focused = key

func test_revealing_another_servers_pane_flies_to_it() -> void:
	var manager := remembered_manager()
	var input := settings()
	var key: String = manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	transport.connected = true
	transport.workspace = "$1"
	transport.topology = {"tabs": [{"id": 20}], "panes": []}
	var here := Node.new()
	var host := FlightHost.new()
	host.workspace_layout.add(10, {"windows": [{"pane": "%1"}, {"pane": "%2"}]})
	host.workspace_layout.add(11, {"pane": "%3"})
	host.workspace_layout.add(20, {"windows": [{"pane": "%4"}, {"pane": "%5", "shown": false}]})
	manager.view = View.new()
	manager.view.host = host
	manager.federation.owners = {10: here, 11: here, 20: transport} as Dictionary[int, Node]
	manager.dialog.hide()
	manager.navigation.enter(manager.navigation.Space.WORKSPACE)
	manager.reveal_pane("%3")
	expect(host.world.flights == 0 and host.landed == ["tab switch"], "A pane of the server on screen stays a tab switch")
	host.landed.clear()
	manager.reveal_pane("%5")
	expect(host.world.flights == 1 and host.landed == ["%5"], "A pane on another server is one session flight that lands on that pane")
	expect(manager.federation.selected == transport and not host.session_switch_in_progress, "The flight selects that server and completes")
	here.free()
	host.free()
	manager.view.free()
	manager.federation.free()
	manager.free()

func test_mobile_restore_and_offline_keep_workspace_intent() -> void:
	var manager := remembered_manager()
	var input := settings()
	var key: String = manager._remember_entry(input, "disconnected", "Ready to connect")
	manager.session_passwords[key] = input.token
	manager.view_state.remember_connection(key)
	manager.dialog.hide()
	manager._restore_last_connection()
	var transport: Node = manager.transports[key]
	expect(manager.open_when_ready == key and transport.workspace.is_empty() and transport.preferred_session == "$1", "Startup authenticates the server before restoring the remembered session")
	expect(manager.restore_cover.visible, "Startup labels the server list while it returns to the last workspace")
	manager.view = View.new()
	manager.view.host = Host.new()
	transport.connected = true
	transport.workspace = "$1"
	transport.topology = {"tabs": [{"id": 10}], "panes": []}
	manager._open_workspace(key)
	expect(manager.navigation.current == manager.navigation.Space.WORKSPACE, "Authenticated topology opens the remembered workspace")
	expect(not manager.restore_cover.visible, "The label goes once the workspace is shown")
	transport._network_failed("test network interruption")
	expect(manager.navigation.current == manager.navigation.Space.WORKSPACE and not manager.chooser.visible, "Transient offline state does not eject the user into the manager")
	expect(manager.transports[key] == transport and transport.enabled, "The existing transport retries, without a duplicate connection")
	manager.open_when_ready = key
	manager._show_chooser()
	expect(manager.open_when_ready.is_empty(), "Intentional manager navigation cancels automatic opening")
	manager._disconnect(key)
	expect(manager.view_state.last_connection.is_empty(), "Explicit disconnect prevents automatic restart reconnection")
	manager.view.host.free()
	manager.view.free()
	manager.federation.free()
	manager.free()

func test_saved_server_has_no_session_field() -> void:
	var manager := remembered_manager()
	manager.view_state.sessions.clear()
	var input := settings()
	var transport: Node = manager.open_connection(input)
	expect(transport.workspace.is_empty() and transport.preferred_session.is_empty(), "Connecting does not invent a session")
	var editor := preload("res://scenes/remote/ServerEditor.gd").new()
	editor.load_settings(input)
	expect(not editor.settings().has("workspace"), "Server editor has no session setting")
	editor.free()
	manager.federation.free()
	manager.free()

func test_restore_without_remembered_password_requires_sign_in() -> void:
	var manager := remembered_manager()
	var input := settings()
	input.erase("token")
	var key: String = manager._remember_entry(input, "disconnected", "Ready to connect")
	manager.view_state.remember_connection(key)
	manager._restore_last_connection()
	expect(manager.transports.is_empty() and manager.states[key].state == "password", "Automatic restore cannot bypass missing credentials")
	expect(not manager.restore_cover.visible, "A server that needs a password shows the list without the label")
	expect(manager.open_when_ready.is_empty(), "Failed automatic restore leaves navigation under user control")
	manager.federation.free()
	manager.free()

func test_restore_ignores_removed_and_transient_connections() -> void:
	var manager := remembered_manager()
	manager.view_state.remember_connection("missing")
	manager._restore_last_connection()
	expect(manager.transports.is_empty(), "Removed servers are not resurrected")
	var input := settings()
	input.transient = true
	var key: String = manager._remember_entry(input, "disconnected", "Ready to connect")
	manager.view_state.remember_connection(key)
	manager._restore_last_connection()
	expect(manager.transports.is_empty(), "Transient invitations are never automatically restored")
	manager.federation.free()
	manager.free()

func test_closed_session_removes_dead_workspace_and_preserves_server() -> void:
	var manager := Manager.new()
	var input := settings()
	var key := manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	transport.connected = true
	transport._set_state("Connected")
	manager._session_closed(key, transport)
	expect(manager.transports.get(key) == transport and transport.connected, "Closing a session preserves its authenticated server connection")
	expect(manager.chooser.visible and manager.states[key].state == "connected", "An empty server stays connected in the chooser")
	expect(manager.entries.has(key) and manager.session_passwords[key] == input.token, "Saved server and credentials survive session closure")
	manager.federation.free()
	manager.free()

func test_connection_card_uses_reported_hostname_without_replacing_alias() -> void:
	var manager := Manager.new()
	var input := settings()
	input.erase("remember")
	input.transient = true
	input.name = ""
	var key := manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	expect(manager.cards[key].heading.text == "127.0.0.1", "Unidentified server uses address host, not full URL")
	transport.server_hostname = "MyMac"
	transport.server_platform = "macos"
	transport.server_username = "developer"
	transport.authenticated.emit()
	expect(manager.cards[key].heading.text == "developer@MyMac" and manager.entries[key].name == "", "Authentication supplies hostname/account without creating an alias")
	expect(manager.entries[key].platform == "macos" and manager.entries[key].username == "developer", "Authenticated identity is retained for disconnected cards")
	manager.entries[key].name = "Work Mac"
	transport.server_hostname = "RenamedMac"
	transport.authenticated.emit()
	expect(manager.cards[key].heading.text == "Work Mac", "A custom alias survives hostname changes")
	transport.server_platform = ""
	transport.server_username = ""
	transport.authenticated.emit()
	expect(manager.entries[key].platform.is_empty() and manager.entries[key].username.is_empty(), "Unavailable identity clears previously cached metadata")
	manager.federation.free()
	manager.free()

func test_connection_error_keeps_credentials_and_ignores_replaced_transports() -> void:
	var manager := Manager.new()
	var input := settings()
	var key := manager._connection_key(input)
	var old: Node = manager.open_connection(input)
	manager._connection_failed("Formatter hyperlink cell mismatch", key, old)
	expect(manager.transports.is_empty() and manager.federation.connections.is_empty(), "Failed transport is removed from the workspace")
	expect(manager.entries.has(key) and manager.session_passwords[key] == input.token, "Server error preserves saved address and valid credentials")
	expect(manager.states[key].state == "error" and manager.cards[key].action.text == "Retry now", "Server card offers explicit recovery")
	var replacement: Node = manager.open_connection(manager.entries[key])
	manager._connection_failed("Late failure", key, old)
	expect(manager.transports[key] == replacement, "A late error cannot detach a replacement connection")
	manager.federation.free()
	manager.free()

func settings() -> Dictionary:
	return {"name": "Test Mac", "url": "ws://127.0.0.1:1", "token": "test-password", "remember": false}

func remembered_manager() -> Node:
	var manager := Manager.new()
	manager.view_state = preload("res://scenes/remote/RemoteViewState.gd").new(cache_directory().path_join("manager-views-%d.json" % Time.get_ticks_usec()))
	manager.view_state.sessions[manager.view_state._server(settings().url)] = "$1"
	return manager

func test_saved_connection_is_server_only_and_view_preference_is_separate() -> void:
	var manager := remembered_manager()
	var input := settings()
	input.erase("remember")
	input.transient = true
	var key: String = manager._remember_entry(input, "disconnected", "Ready to connect")
	expect(key == input.url, "Server identity never includes the selected session")
	var transport: Node = manager.open_connection(input)
	expect(transport.workspace.is_empty() and transport.preferred_session == "$1", "View preference is applied only after session discovery")
	expect(not manager.entries[key].has("workspace"), "Saved server contains no session target")
	manager._edit_connection(key)
	expect(not manager.pending_settings.has("workspace"), "Server editor does not edit view selection")
	manager.federation.free()
	manager.free()

func test_server_card_keeps_session_selection_internal_across_reconnect() -> void:
	var manager := remembered_manager()
	var input := settings()
	input.erase("remember")
	input.transient = true
	var key: String = manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	transport.connected = true
	transport.authenticated.emit()
	transport.workspace = "1"
	transport.session_switched.emit()
	var identity: String = manager.cards[key].select.accessibility_name
	expect(manager.view_state.session(input.url) == "1", "Authentication remembers the server's actual fallback internally")
	transport.workspace = "2"
	transport.session_switched.emit()
	expect(manager.view_state.session(input.url) == "2" and manager.cards[key].select.accessibility_name == identity, "Switching sessions updates the internal view preference without changing server details")
	manager._disconnect(key)
	var replacement: Node = manager.open_connection(manager.entries[key])
	expect(replacement.workspace.is_empty() and replacement.preferred_session == "2" and manager.entries.size() == 1, "Reconnect resumes the displayed session without duplicating the saved server")
	manager.federation.free()
	manager.free()

func test_disconnect_keeps_server_and_reconnect_does_not_duplicate() -> void:
	var manager := Manager.new()
	var input := settings()
	var key := manager._connection_key(input)
	var old: Node = manager.open_connection(input)
	manager._disconnect(key)
	expect(manager.entries.has(key) and manager.cards.has(key), "Disconnect preserves the server and its visible card")
	expect(manager.federation.connections.is_empty(), "Disconnect stops the transport")
	expect(manager.states[key].state == "disconnected", "Card explicitly reports disconnection")
	manager.open_connection(manager.entries[key])
	manager.open_connection(manager.entries[key])
	expect(manager.federation.connections.size() == 1, "Repeated reconnect replaces rather than duplicates transports")
	expect(manager.transports[key] != old, "Reconnect uses a new transport")
	expect(not manager.entries[key].has("token"), "Server metadata never contains its password")
	manager.federation.free()
	manager.free()

func test_offline_card_exposes_recovery() -> void:
	var manager := Manager.new()
	var input := settings()
	var key := manager._connection_key(input)
	var transport: Node = manager.open_connection(input)
	transport._network_failed("Server unreachable")
	expect(manager.states[key].state == "offline", "Failure is visible without opening another dialog")
	expect(manager.cards[key].action.text == "Retry now" and not manager.cards[key].action.disabled, "Offline has an enabled retry action")
	manager.federation.free()
	manager.free()

func test_blank_address_is_rejected() -> void:
	var manager := Manager.new()
	expect(manager.open_connection({}) == null, "Incomplete connection data is rejected")
	expect(manager.entries.is_empty(), "Invalid address does not create an unusable card")
	manager.federation.free()
	manager.free()

func test_password_required_is_a_persistent_state() -> void:
	var manager := Manager.new()
	var input := settings()
	input.erase("token")
	var key := manager._remember_entry(input, "password", "Password needed")
	expect(manager.cards[key].action.text == "Enter current password", "Missing password has a clear action on the server card")
	expect(manager.entries[key].url == input.url, "Password recovery retains the address")
	manager.federation.free()
	manager.free()

class ConnectOnlyManager extends "res://scenes/remote/RemoteManager.gd":
	var attempts: Array[String] = []
	var starts := 0
	func open_connection(settings: Dictionary) -> Node:
		attempts.append(str(settings.url))
		return null
	func _start_connected_workspace() -> void:
		starts += 1

func test_server_activation_connects_without_navigation_and_connect_all_starts() -> void:
	var manager := ConnectOnlyManager.new()
	for state in ["connected", "connecting", "authenticating", "disconnected"]:
		manager.entries[state] = {"url": state}
		manager.states[state] = Manager.ConnectionState.new(state, "", [])
		manager._activate(state)
	expect(manager.attempts == ["disconnected"], "Cards only start idle connections and preserve existing attempts")
	expect(manager.open_when_ready.is_empty() and manager.starts == 0, "Individual connection does not request terminal navigation")
	manager.attempts.clear()
	manager._connect_all()
	expect(manager.attempts == ["disconnected"], "Connect all leaves connected and connecting servers alone")
	expect(manager.starts == 1 and manager._open_all_when_ready, "Connect all starts a ready workspace or waits for one")
	manager.federation.free()
	manager.free()
