extends "res://tests/unit/test_case.gd"

func test_presentation_settings_belong_to_view() -> void:
	var host := preload("res://scenes/TerminalHost.gd").new()
	var labels: Array = host._workspace_menu_entries().map(func(entry): return entry.label)
	for title in ["Effects…", "Appearance…", "Fonts…"]:
		expect(labels.count("View::" + title) == 1, title + " appears once in View")
		expect(not labels.has("Edit::" + title), title + " is absent from Edit")
	host.free()

func test_fonts_menu_requires_a_local_transport_not_a_federation() -> void:
	var host := preload("res://scenes/TerminalHost.gd").new()
	var transport := preload("res://scenes/remote/RemoteConnection.gd").new()
	host.session_backend = preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
	host.session_backend.connection = null
	var entry: Dictionary = {}
	for candidate in host._workspace_menu_entries():
		if candidate.label == "View::Fonts…": entry = candidate
	expect(not entry.is_empty(), "Fonts menu entry exists")
	expect(not host.menu_entry_state(entry).enabled, "No transport disables local font settings")
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	host.session_backend.connection = federation
	expect(not host.menu_entry_state(entry).enabled, "Federated Android connections disable local fonts without accessing a URL")
	host.session_backend.connection = transport
	transport.url = "wss://example.com"
	expect(not host.menu_entry_state(entry).enabled, "Remote transport cannot edit local server fonts")
	transport.url = "shared://local"
	expect(host.menu_entry_state(entry).enabled, "Local shared transport can edit fonts")
	transport.free()
	federation.free()
	host.free()


class TwoServers extends "res://scenes/session/SessionBackend.gd":
	## Tabs 1, 2 and 5 belong to one server's session; 3 and 4 to another's.
	func session_scope(tab: int) -> int: return 2 if tab in [3, 4] else 1


func test_tab_strip_holds_only_the_active_sessions_tabs() -> void:
	var host := preload("res://scenes/TerminalHost.gd").new()
	host.session_backend = TwoServers.new()
	for id in [1, 2, 3, 4, 5]: host.workspace_layout.tabs.append({"id": id, "tree": {}, "title": "T%d" % id})
	host.workspace_layout.active = 3
	expect(host.get_tabs(true).map(func(tab): return tab.id) == [3, 4], "The strip shows the active session's tabs only")
	expect(host.get_tabs().size() == 5, "The window still holds every session's tabs")
	expect(host.get_tab_menu_items().map(func(tab): return tab.id) == [3, 4], "The tab menu lists the same session")
	host.workspace_layout.active = 1
	expect(host.get_tabs(true).map(func(tab): return tab.id) == [1, 2, 5], "Changing session changes the whole strip")
	# Dragging the first tab to the end of its strip must not cross sessions.
	host.move_session(1, 2)
	expect(host.session_tabs().map(func(tab): return tab.id) == [2, 5, 1], "A tab reorders within its own strip")
	expect(host.workspace_layout.tabs.map(func(tab): return tab.id).filter(func(id): return id in [3, 4]) == [3, 4], "Other sessions keep their order")
	host.free()

func test_touch_does_not_leave_a_hover_target_for_font_shortcuts() -> void:
	var host := preload("res://scenes/TerminalHost.gd").new()
	# A visible overlay stops later input routing; source tracking still applies.
	host.dictation_preview = Control.new()
	host._input(InputEventScreenTouch.new())
	expect(not host.pointer_can_hover, "Touch does not target a panel through mouse hover")
	var emulated := InputEventMouseMotion.new()
	emulated.device = InputEvent.DEVICE_ID_EMULATION
	host._input(emulated)
	expect(not host.pointer_can_hover, "The synthesized mouse event preserves touch routing")
	host._input(InputEventMouseMotion.new())
	expect(host.pointer_can_hover, "A physical mouse restores pointer-targeted panel shortcuts")
	host.dictation_preview.free()
	host.free()
