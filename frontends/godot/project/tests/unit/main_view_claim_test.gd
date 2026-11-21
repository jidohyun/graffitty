extends "res://tests/unit/test_case.gd"
## The client used last sizes the shared main area; others letterbox it.
const Backend := preload("res://scenes/session/RemoteSessionBackend.gd")
const Workspace := preload("res://scenes/session/ServerWorkspace.gd")
const FIT := Rect2(0, 34, 1280, 766)
const SERVER := Rect2(0, 34, 1024, 734)
const PHONE := Rect2(0, 34, 412, 846)

class Transport extends Node:
	signal acknowledged(message: Dictionary)
	signal state_changed(message: String)
	signal changed
	var connected := true
	var topology: Dictionary = {}
	var topology_generation := 0
	var topology_received_revision := 1
	var sent: Array[Dictionary] = []
	func wire_id(id: int) -> int: return id
	func send_action(_kind: String, _id: int, values: Dictionary) -> int:
		sent.append(values.duplicate(true))
		return 40 + sent.size()

class View extends Control:
	## What this window offers the main area, and what is visible of it.
	var fit := Rect2(0, 34, 1280, 766)
	var visible_area := Rect2(0, 34, 1280, 766)
	var panes := {}
	func window_fit_rect() -> Rect2: return fit
	func viewport_content_rect() -> Rect2: return visible_area

class Federation extends Node:
	signal acknowledged(message: Dictionary)
	var connections: Array[Node] = []
	var owners: Dictionary = {}

class Host extends Node:
	var sessions := {}
	var layout_transaction := false
	var application := {"checkpoints": {"importing": false}}
	var workspace_view := View.new()
	var workspace_layout := {"active": 1, "tabs": [{"id": 1, "focused": "%1",
		"tree": {"windows": [{"pane": "%1", "rect": Rect2(8, 42, 1000, 700)}]}}]}


class TerminalStub extends Node:
	var grid := Vector2i(80, 24)
	func get_grid_size() -> Vector2i: return grid


func test_arrival_waits_for_claim_topology_resize_and_matching_scene() -> void:
	var f := fixture("other")
	f.backend.sync_window_area(f.host)
	expect(not f.backend.transition_layout_ready(f.host), "An unacknowledged claim cannot supply arrival geometry")
	f.transport.topology.workspace_state.revision += 1
	f.backend._workspace_ack({"type": "ack", "request": f.backend.pending_edit, "workspace_state": f.transport.topology.workspace_state})
	expect(not f.backend.transition_layout_ready(f.host), "The claim acknowledgement still needs the new topology")
	topology(f, "self", FIT)
	var terminal := TerminalStub.new()
	var pane := Control.new()
	f.host.sessions[1] = {"term": terminal}
	f.host.workspace_view.panes["%1"] = pane
	f.transport.topology.panes = [{"id": 1, "tab": 1, "columns": 100, "rows": 30}]
	expect(not f.backend.transition_layout_ready(f.host), "A painted old grid cannot stand in for the resized scene")
	terminal.grid = Vector2i(100, 30)
	f.backend.pending_operations[55] = {"resize": 1}
	expect(not f.backend.transition_layout_ready(f.host), "A newer pane resize must finish before arrival")
	f.backend._workspace_ack({"type": "ack", "request": 55})
	f.backend.pending_operations[56] = {"resize": 2}
	f.backend.queued_edits["tab:2"] = {"op": "tab", "tab": 2}
	expect(f.backend.transition_layout_ready(f.host), "Matching destination geometry proceeds without waiting on other tabs")
	terminal.free()
	pane.free()
	release(f)


func fixture(owner: String, fit := true) -> Dictionary:
	var host := Host.new()
	host.workspace_view.size = Vector2(1280, 800)
	var transport := Transport.new()
	var area := [SERVER.position.x, SERVER.position.y, SERVER.size.x, SERVER.size.y]
	transport.topology = {"authoritative_layout": true, "workspace_revision": 1,
		"tabs": [{"id": 1, "size_owner": owner}],
		"workspace_state": {"revision": 1, "layout": {"tabs": {"1": Workspace.encode_tab(host.workspace_layout.tabs[0])}},
			"tabs": {"1": {"area": area.duplicate()}}, "active": 1, "order": [1]}}
	var backend := Backend.new(transport)
	backend.fit_main_view = fit
	return {"host": host, "transport": transport, "backend": backend}


func release(f: Dictionary) -> void:
	f.host.workspace_view.free()
	f.host.free()
	f.transport.free()


static func rect_of(area: Array) -> Rect2:
	return Rect2(area[0], area[1], area[2], area[3])


func claims(f: Dictionary) -> Array:
	return f.transport.sent.filter(func(message): return message.get("claim", false))


## A topology from the owner, as each client receives it.
func topology(f: Dictionary, owner: String, area: Rect2) -> void:
	var value := [area.position.x, area.position.y, area.size.x, area.size.y]
	f.transport.topology.tabs = [{"id": 1, "size_owner": owner}]
	f.transport.topology.workspace_state.tabs["1"].area = value.duplicate()
	f.transport.topology_generation += 1
	f.transport.topology_received_revision = int(f.transport.topology.workspace_state.revision)


## The owner applies the last edit. Its acknowledgement patches workspace
## state first; the topology naming the new owner follows.
func accept(f: Dictionary, owner := "self") -> void:
	var message: Dictionary = f.transport.sent.back()
	var state: Dictionary = f.transport.topology.workspace_state
	state.revision += 1
	state.tabs["1"].area = message.edit.settings.area.duplicate()
	f.transport.topology.workspace_revision = state.revision
	f.backend._workspace_ack({"type": "ack", "request": f.backend.pending_edit, "workspace_state": state})
	topology(f, owner, rect_of(message.edit.settings.area))


func test_attaching_with_fit_claims_the_main_area_for_this_window() -> void:
	var f := fixture("none")
	f.backend.sync_window_area(f.host)
	expect(claims(f).size() == 1, "A fitting client claims the main area when it attaches")
	if claims(f).size() == 1:
		expect(rect_of(claims(f)[0].edit.settings.area) == FIT, "The claim carries this window's main area")
	expect(f.backend.content_rect(f.host, SERVER) == FIT, "The claiming window lays out at its own size before the owner confirms")
	accept(f)
	f.backend.sync_window_area(f.host)
	expect(f.transport.sent.size() == 1 and f.backend.claiming.is_empty(), "A confirmed claim settles without repeating")
	expect(f.backend.content_rect(f.host, SERVER) == FIT, "The owner keeps laying out at its own size")
	release(f)


func test_a_claim_stays_provisional_until_the_topology_names_its_owner() -> void:
	var f := fixture("other")
	f.backend.sync_window_area(f.host)
	var state: Dictionary = f.transport.topology.workspace_state
	state.revision += 1
	f.transport.topology.workspace_revision = state.revision
	f.backend._workspace_ack({"type": "ack", "request": f.backend.pending_edit, "workspace_state": state})
	f.backend.sync_window_area(f.host)
	expect(f.backend.content_rect(f.host, SERVER) == FIT, "An acknowledgement alone cannot letterbox the claimant with the old owner's snapshot")
	release(f)


func test_claim_accepts_topology_before_its_batched_acknowledgement() -> void:
	var f := fixture("other")
	f.backend.sync_window_area(f.host)
	f.transport.topology.workspace_state.revision += 1
	topology(f, "self", FIT)
	expect(not f.backend.transition_layout_ready(f.host), "Topology alone still waits for the claim acknowledgement")
	f.backend._workspace_ack({"type": "ack", "request": f.backend.pending_edit, "workspace_state": f.transport.topology.workspace_state})
	expect(f.backend.transition_layout_ready(f.host), "Confirmed topology releases arrival immediately when the batched acknowledgement arrives")
	expect(f.backend.claiming.is_empty(), "No extra topology or timeout is needed")
	release(f)


func test_following_clients_letterbox_and_never_claim() -> void:
	var f := fixture("other", false)
	f.backend.sync_window_area(f.host)
	f.backend.note_activity(f.host)
	f.host.workspace_view.fit = PHONE
	f.backend.sync_window_area(f.host)
	expect(f.transport.sent.is_empty(), "Follow Server never resizes the shared main area, even when this window changes")
	expect(f.backend.content_rect(f.host, FIT) == SERVER, "A following window letterboxes the server's area")
	release(f)


func test_input_on_this_client_takes_the_area_back() -> void:
	var f := fixture("other")
	f.backend.attach_claim = false
	f.backend.sync_window_area(f.host)
	expect(f.transport.sent.is_empty(), "A refresh never takes the area from the client used last")
	expect(f.backend.content_rect(f.host, FIT) == SERVER, "Until then this window letterboxes the other client's area")
	f.backend.note_activity(f.host)
	expect(claims(f).size() == 1, "Input here claims the area")
	if claims(f).size() == 1:
		expect(rect_of(claims(f)[0].edit.settings.area) == FIT, "The claim carries this window's size")
	f.backend.note_activity(f.host)
	expect(f.transport.sent.size() == 1, "Further input does not repeat an outstanding claim")
	release(f)


func test_resizing_this_window_wins_over_a_client_used_earlier() -> void:
	var f := fixture("other")
	f.backend.attach_claim = false
	f.backend.sync_window_area(f.host)
	f.host.workspace_view.fit = Rect2(0, 34, 1440, 866)
	f.backend.sync_window_area(f.host)
	expect(claims(f).size() == 1, "Resizing this window is the latest activity, even while another client holds the area")
	if claims(f).size() == 1:
		expect(rect_of(claims(f)[0].edit.settings.area) == Rect2(0, 34, 1440, 866), "The claim carries the new window size")
	release(f)


func test_the_soft_keyboard_reclaims_the_available_area() -> void:
	var f := fixture("other")
	f.backend.attach_claim = false
	f.backend.sync_window_area(f.host)
	f.host.workspace_view.visible_area = Rect2(0, 34, 1280, 400)
	f.host.workspace_view.fit = f.host.workspace_view.visible_area
	f.backend.sync_window_area(f.host)
	expect(claims(f).size() == 1, "Opening the keyboard claims the reduced usable area")
	expect(rect_of(claims(f)[0].edit.settings.area) == Rect2(0, 34, 1280, 400), "The keyboard claim carries the area above the IME")
	release(f)


func test_manager_claims_keep_each_servers_revision_and_acknowledgement_separate() -> void:
	var first := fixture("other")
	var second := fixture("other")
	# Two connections can use the same request number while their workspace
	# revisions and mapped tab IDs are unrelated.
	second.transport.topology.workspace_revision = 73
	second.transport.topology.tabs[0].id = 2
	var snapshot: Dictionary = second.transport.topology.workspace_state
	snapshot.layout.tabs["2"] = snapshot.layout.tabs["1"]
	snapshot.layout.tabs.erase("1")
	snapshot.tabs["2"] = snapshot.tabs["1"]
	snapshot.tabs.erase("1")
	snapshot.active = 2
	snapshot.order = [2]
	var second_tab: Dictionary = second.host.workspace_layout.tabs[0].duplicate(true)
	second_tab.id = 2
	first.host.workspace_layout.tabs.append(second_tab)
	var federation := Federation.new()
	federation.connections.assign([first.transport, second.transport])
	federation.owners = {1: first.transport, 2: second.transport}
	var backend := Backend.new(federation)
	backend.sync_window_area(first.host)
	expect(claims(first).size() == 1 and claims(second).size() == 1, "The server manager claims both independent owners")
	expect(claims(first)[0].expected_revision == 1 and claims(second)[0].expected_revision == 73, "Each claim uses its own server revision")
	expect(claims(first)[0].edit.tab == 1 and claims(second)[0].edit.tab == 2, "Each claim targets only its owning tab")
	expect(first.transport.sent.size() == 1 and second.transport.sent.size() == 1, "Area claims do not reorder or activate another server's tabs")
	first.transport.acknowledged.emit({"type": "ack", "request": 41, "workspace_state": {"revision": 2}})
	expect(backend.area_backends[first.transport].pending_edit == -1, "First server acknowledgement settles its edit")
	expect(backend.area_backends[second.transport].pending_edit == 41, "An equal request number on another server remains pending")
	second.transport.acknowledged.emit({"type": "ack", "request": 41, "workspace_state": {"revision": 74}})
	expect(not backend.work_pending(), "Both server edits complete independently")
	backend.fit_main_view = false
	first.host.workspace_layout.active = 2
	snapshot.tabs["2"].area = [PHONE.position.x, PHONE.position.y, PHONE.size.x, PHONE.size.y]
	expect(backend.content_rect(first.host, FIT) == PHONE, "Following a federated tab reads its owning server's canonical area")
	federation.free()
	release(first)
	release(second)


func test_a_newer_claim_elsewhere_is_not_fought() -> void:
	var f := fixture("none")
	f.backend.sync_window_area(f.host)
	accept(f)
	f.backend.sync_window_area(f.host)
	topology(f, "other", PHONE)
	f.backend.sync_window_area(f.host)
	expect(f.transport.sent.size() == 1, "The previous owner does not push its size back")
	expect(f.backend.content_rect(f.host, FIT) == PHONE, "It letterboxes the newer claim")
	release(f)


func test_a_claim_vacated_by_reconnecting_is_resumed_but_a_taken_one_is_not() -> void:
	var f := fixture("none")
	f.backend.sync_window_area(f.host)
	accept(f)
	f.backend.sync_window_area(f.host)
	# The connection dropped; the owner released the claim but kept the area.
	topology(f, "none", FIT)
	f.host.workspace_view.fit = Rect2(0, 34, 1280, 700)
	f.backend.observed_fit = f.host.workspace_view.fit
	f.backend.sync_window_area(f.host)
	expect(claims(f).size() == 2, "A claim only this client's disconnection vacated is taken back")
	var other := fixture("none")
	other.backend.sync_window_area(other.host)
	accept(other)
	other.backend.sync_window_area(other.host)
	topology(other, "other", PHONE)
	other.backend.sync_window_area(other.host)
	topology(other, "none", PHONE)
	other.backend.sync_window_area(other.host)
	expect(claims(other).size() == 1, "Another client's departure hands nothing over: the area stays as left")
	release(f)
	release(other)


func test_a_claim_overrides_an_area_set_meanwhile_instead_of_conflicting() -> void:
	var f := fixture("other")
	f.backend.attach_claim = false
	f.backend.pending_edit = 40
	f.backend.note_activity(f.host)
	# Another client's claim lands first and advances the owner revision.
	topology(f, "other", PHONE)
	f.transport.topology.workspace_revision += 1
	f.transport.topology.workspace_state.revision += 1
	f.backend._workspace_ack({"type": "error", "request": 40,
		"message": "Workspace revision conflict: expected 1, current 2",
		"workspace_state": f.transport.topology.workspace_state})
	expect(claims(f).size() == 1, "The latest activity is still sent after the revision moved")
	if claims(f).size() == 1:
		expect(rect_of(claims(f)[0].edit.settings.area) == FIT, "It replaces the area set meanwhile")
	expect(f.backend.work_pending() and not f.backend.claiming.is_empty(), "No conflict is reported for the area")
	release(f)


func test_switching_to_fit_takes_the_area_immediately() -> void:
	var f := fixture("other", false)
	f.backend.attach_claim = false
	f.backend.set_fit_main_view(f.host, true)
	expect(claims(f).size() == 1, "Choosing Fit to This Window claims at once")
	f.backend.set_fit_main_view(f.host, false)
	expect(f.backend.claiming.is_empty() and f.backend.content_rect(f.host, FIT) == SERVER, "Choosing Follow Server stops sizing and letterboxes")
	release(f)


func test_newer_owner_settles_claim_without_a_geometry_refresh() -> void:
	var f := fixture("none")
	f.backend.sync_window_area(f.host)
	accept(f)
	# Metadata-only topology no longer reinstalls the entire workspace layout.
	# A later owner must win even if sync_window_area has not run again.
	topology(f, "other", PHONE)
	expect(f.backend.content_rect(f.host, SERVER) == PHONE, "A newer owner supersedes an acknowledged provisional claim immediately")
	f.backend.commit_workspace(f.host)
	expect(f.transport.sent.size() == 1, "An unrelated UI refresh cannot overwrite the newer owner's area")
	release(f)
