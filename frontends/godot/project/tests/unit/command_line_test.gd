extends "res://tests/unit/test_case.gd"
const Model := preload("res://scenes/CommandLineModel.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Prefix := preload("res://scenes/WorkspacePrefix.gd")

class App extends Node:
	var hosts: Array = []
	var checkpoints: Node

class SessionPeer extends Node:
	var workspace := "$1"
	var connected := true
	var display_name := ""
	var available_sessions := [{"id":"$1", "name":"main", "automatic_name":null}, {"id":"$2", "name":"notes", "automatic_name":null}, {"id":"$3", "name":"work", "automatic_name":null}]
	var calls: Array = []
	func request_action(kind: String, values: Dictionary) -> Dictionary:
		calls.append([kind, values])
		return {"type": "ack"}

class MultiConnection extends Node:
	var connections: Array = []
	var owners := {}
	var selected: Node
	var connected := true

class RemoteBackend extends RefCounted:
	var is_remote := true
	var connection: Node

class Host extends Node:
	signal ui_changed
	var application: Node
	var active_session_id := 0
	var server_chooser := Callable()
	var workspace_layout = Layout.new()
	var menu_entries: Array = []
	var titles := {}
	var calls: Array = []
	var restored: Array = []
	var session_backend: RefCounted = preload("res://scenes/session/SessionBackend.gd").new()
	func get_tabs() -> Array:
		return workspace_layout.tabs.map(func(tab): return {"id": tab.id, "title": "tab %d" % tab.id})
	func pane_title(key: String) -> String:
		return titles.get(key, key)
	func menu_entry_specs() -> Array:
		return menu_entries
	func menu_entry_state(entry: Dictionary) -> Dictionary:
		return {"enabled": entry.get("enabled_now", true), "checked": entry.get("checked_now", false)}
	func select_workspace(id: int, _instant := false) -> void:
		calls.append(["tab", id])
	func reveal_pane(key: String) -> void:
		calls.append(["pane", key])
	func restore_checkpoint(tag: String, checkpoint: String) -> void:
		restored.append([tag, checkpoint])
	func _on_menu_action(entry: Variant) -> void:
		if entry is Dictionary and entry.get("action") is Callable:
			entry.action.call(self)
		else:
			calls.append(["command", entry.label])
	func shortcut_text(action: String) -> String:
		return Prefix.key_label(get_meta(action)) if has_meta(action) else ""

func setup() -> Array:
	var app := App.new()
	var host := Host.new()
	host.application = app
	app.hosts = [host]
	host.workspace_layout.add(9, {"windows": [{"pane": "%9"}, {"pane": "%12", "shown": false}]})
	host.workspace_layout.add(31, {"pane": "%31"})
	for id in range(40, 48):
		host.workspace_layout.add(id, {"pane": "%%%d" % id})
	host.titles = {"%9": "nvim", "%12": "Chromium · localhost:3000"}
	var noop := func(_host): pass
	host.menu_entries = [
		{"label": "Shell::New Pane Right", "action": "NewPaneRight"},
		{"label": "Shell::New Tab", "action": "NewTab"},
		{"label": "Sessions::Remote separator", "action": "Separator"},
		{"label": "Edit::Find…", "action": "Find"},
		{"label": "View::Tiling", "action": "ToggleTiling", "checked_now": true},
		{"label": "View::Cursor Trail::Smear", "action": noop},
		{"label": "Shell::Close Pane", "action": "ClosePane", "enabled_now": false},
		{"label": "Sessions::Save checkpoint and quit", "action": "SaveCheckpointAndQuit"},
	]
	var model := Model.new()
	model.host = host
	return [app, host, model]

func labels(model: Model) -> Array:
	return model.rows.map(func(row): return row.candidate.label)

func row_for(model: Model, label: String) -> Dictionary:
	for row in model.rows:
		if row.candidate.label == label:
			return row
	return {}

func typed(unicode: int, keycode := KEY_NONE, shift := false, ctrl := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.unicode = unicode
	event.keycode = keycode
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.pressed = true
	return event

func test_native_ranker_is_built() -> void:
	expect(ClassDB.class_exists("FuzzyRanker"), "FuzzyRanker comes from the native extension; rebuild it if this fails")

func test_number_mode_lists_tabs_and_one_based_panes() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("1")
	expect(labels(model)[0] == "1" and model.rows[0].tier == Model.Tier.EXACT, "1 ranks tab one first")
	var prefixed := labels(model).slice(1, 5)
	prefixed.sort()
	expect(prefixed == ["1.1", "1.2", "10", "10.1"], "Then its panes from 1, and tab ten")
	expect(model.rows.slice(1, 5).all(func(row): return row.tier == Model.Tier.PREFIX), "Those are prefix matches")
	var pane: Dictionary = row_for(model, "1.2").candidate
	expect(pane.key == "%12" and pane.detail == "%12" and pane.hidden, "Panes show their ID and hidden state")
	expect(pane.title == "Chromium · localhost:3000", "Panes show their title")
	expect(row_for(model, "1").candidate.detail == "@9", "Tabs show their stable ID")
	model.set_text("99")
	expect(model.rows.is_empty() and model.status() == "No matches", "A missing tab matches nothing")
	model.set_text("12")
	expect(not labels(model).has("13"), "Numbers never match other numbers")
	host.free()
	fixture[0].free()

func test_ids_address_panes_and_tabs() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("%12")
	var pane: Dictionary = model.rows[0].candidate
	expect(pane.label == "%12" and pane.key == "%12" and pane.detail == "1.2", "%ID finds a pane and shows its position")
	model.set_text("@31")
	expect(model.rows[0].candidate.kind == "tab" and model.rows[0].candidate.id == 31, "@ID finds a tab")
	model.set_text("@9.2")
	expect(model.rows[0].candidate.key == "%12", "@ID.N numbers that tab's panes from 1")
	host.free()
	fixture[0].free()

func test_pane_candidates_follow_main_reading_order() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	var tree: Dictionary = host.workspace_layout.tab(9).tree
	tree.tiling = true
	tree.windows[0].stashed = true
	tree.windows[1].shown = true
	tree.windows.append({"pane": "%13"})
	tree.tiles = {"axis": "h", "children": [{"pane": "%13"}, {"pane": "%12"}]}
	model.set_text("1.")
	expect(row_for(model, "1.1").candidate.key == "%13", "First command-line number selects the left Main pane")
	expect(row_for(model, "1.2").candidate.key == "%12", "Second command-line number selects the right Main pane")
	expect(row_for(model, "1.3").candidate.key == "%9", "Stashed pane follows Main in command-line navigation")
	model.set_text("%9")
	expect(model.rows[0].candidate.detail == "1.3", "Stable-ID results show the matching positional address")
	host.free()
	fixture[0].free()


func test_commands_use_action_names() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("")
	expect(labels(model) == ["NewPaneRight", "NewTab", "Find", "ToggleTiling", "CursorTrailSmear", "SaveCheckpointAndQuit"], "Enabled commands in menu order, without separators or unmenued actions")
	expect(model.rows.all(func(row): return row.tier == Model.Tier.UNFILTERED), "An empty line lists everything unranked")
	expect(row_for(model, "ToggleTiling").candidate.checked, "Toggles carry their checked state")
	expect(model.accepted().is_empty(), "Enter on an empty line runs nothing")
	model.set_text("new pane right")
	expect(labels(model)[0] == "NewPaneRight" and model.rows[0].tier == Model.Tier.EXACT, "Spaces and case are forgiven")
	expect(model.rows[0].candidate.entry.label == "Shell::New Pane Right", "A menued action runs its menu entry")
	model.set_text("focus-left")
	expect(labels(model)[0] == "FocusLeft" and model.rows[0].candidate.title == "Focus Left", "Actions without a menu entry are reachable by name")
	model.set_text("sendtext")
	expect(not labels(model).has("SendText") and not labels(model).has("Ignore"), "Key-routing actions need their binding's parameters")
	model.set_text("closepane")
	expect(not labels(model).has("ClosePane"), "A disabled menu entry hides its action")
	expect(Model.command_name(PackedStringArray(["View", "Cursor Trail", "Smear"])) == "CursorTrailSmear", "Submenus join the name")
	expect(Model.command_name(PackedStringArray(["Edit", "Input Settings…"])) == "InputSettings", "Punctuation is dropped")
	expect(Model.command_name(PackedStringArray(["세션", "저장"])) == "저장", "Non-ASCII labels keep their letters")
	host.free()
	fixture[0].free()

func test_enter_runs_only_spelled_out_matches() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("newpaner")
	expect(model.accepted().candidate.label == "NewPaneRight", "Enter runs the best prefix match")
	model.set_text("nwpnrgt")
	expect(model.rows[0].tier == Model.Tier.FUZZY and model.accepted().is_empty(), "A fuzzy-only match needs an explicit choice")
	expect(model.status() == "Only fuzzy matches: Tab to choose", "The line says why")
	model.cycle(1)
	expect(model.text == labels(model)[0] and model.query == "nwpnrgt", "Tab previews the row without re-ranking")
	expect(not model.accepted().is_empty(), "A chosen fuzzy row runs")
	model.set_text("andquit")
	expect(model.accepted().candidate.label == "SaveCheckpointAndQuit", "Substring matches run")
	host.free()
	fixture[0].free()

func test_notification_command_opens_the_notifications_menu_action() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	host.menu_entries.append({"label": "View::Notifications", "action": "Notifications"})
	model.set_text("Notifications")
	expect(model.accepted().candidate.label == "Notifications" and model.rows[0].tier == Model.Tier.EXACT, "The action name matches exactly")
	model.execute(model.accepted())
	expect(host.calls == [["command", "View::Notifications"]], "The command opens history, independently of Messages")
	host.free()
	fixture[0].free()

func test_selection_cycles_and_moves() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("split")
	var found := labels(model)
	model.cycle(1)
	model.cycle(1)
	expect(model.text == found[1] and model.selected == 1, "Tab walks down the list")
	for step in found.size() - 1:
		model.cycle(1)
	expect(model.text == found[0], "and wraps")
	model.cycle(-1)
	expect(model.text == found[-1], "Shift-Tab walks back")
	model.move(1)
	expect(model.selected == 0 and model.text == found[-1], "Arrows move without changing the line")
	model.set_text("spl")
	expect(model.selected == -1, "Typing clears the choice")
	host.free()
	fixture[0].free()

func index_of(model: Model, key: String) -> int:
	for index in model.rows.size():
		if model.rows[index].candidate.get("key", "") == key:
			return index
	return -1

func test_choice_follows_the_pane_across_renumbering() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("1")
	model.select(index_of(model, "%12"))
	expect(model.accepted().candidate.label == "1.2", "1.2 is chosen")
	host.workspace_layout.reorder(31, 0)
	model.refresh()
	var chosen: Dictionary = model.accepted().candidate
	expect(chosen.key == "%12" and chosen.label == "2.2", "Another client reorders tabs: the same pane stays chosen under its new number")
	expect(model.rows[model.selected].candidate.key == "%12", "It stays listed and highlighted although 2.2 no longer matches 1")
	host.free()
	fixture[0].free()

func test_tab_preview_follows_renumbering() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("1")
	for attempt in 20:
		if model.selected >= 0 and model.rows[model.selected].candidate.get("key", "") == "%12":
			break
		model.cycle(1)
	expect(model.text == "1.2", "Tab previews 1.2")
	host.workspace_layout.reorder(31, 0)
	model.refresh()
	expect(model.text == "2.2" and model.query == "1", "The preview shows the pane's new number")
	host.free()
	fixture[0].free()

func test_closed_choice_never_falls_back_to_another_row() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	model.set_text("1")
	model.select(index_of(model, "%12"))
	host.workspace_layout.take_pane("%12")
	model.refresh()
	expect(model.selected == -1 and model.accepted().is_empty(), "A closed choice runs nothing, not the new top row")
	expect(model.status() == "The chosen row closed: choose again", "The line says why")
	model.move(1)
	expect(not model.accepted().is_empty(), "Choosing again works")
	model.set_text("1")
	expect(model.accepted().candidate.label == "1", "Typing restores the normal Enter rule")
	host.free()
	fixture[0].free()

func test_execute_runs_targets_and_commands() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	for text in ["2", "1.2", "find"]:
		model.set_text(text)
		model.execute(model.accepted())
	expect(host.calls == [["tab", 31], ["pane", "%12"], ["command", "Edit::Find…"]], "Tabs select, panes reveal, commands run")
	host.free()
	fixture[0].free()

func test_key_labels_use_macos_symbols() -> void:
	expect(Prefix.key_label(KEY_T | KEY_MASK_META | KEY_MASK_SHIFT, true) == "⇧⌘T", "macOS writes ⇧⌘T")
	expect(Prefix.key_label(KEY_X | KEY_MASK_CTRL | KEY_MASK_ALT | KEY_MASK_SHIFT | KEY_MASK_META, true) == "⌃⌥⇧⌘X", "Modifiers follow Apple's order")
	expect(Prefix.key_label(KEY_ENTER | KEY_MASK_META, true) == "⌘↩", "Named keys use their symbols")
	expect(Prefix.key_label(KEY_BACKSLASH | KEY_MASK_SHIFT, true) == "⇧\\", "Punctuation stays literal")
	expect(Prefix.key_label(KEY_T | KEY_MASK_CTRL | KEY_MASK_SHIFT, false) == "Ctrl+Shift+T", "Other platforms spell modifiers out")
	expect(Prefix.key_label(KEY_EQUAL | KEY_MASK_CTRL, false) == "Ctrl+=", "Punctuation is literal everywhere")

func test_bindings_hint_their_commands() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	host.menu_entries.append({"label": "Edit::Copy Mode", "action": "CopyMode"})
	host.set_meta("CopyMode", KEY_X | KEY_MASK_CTRL | KEY_MASK_SHIFT)
	host.set_meta("FocusLeft", KEY_H | KEY_MASK_ALT)
	model.set_text("copy-mode")
	expect(model.rows[0].candidate.detail == Prefix.key_label(KEY_X | KEY_MASK_CTRL | KEY_MASK_SHIFT), "Copy mode shows its bound shortcut")
	model.set_text("FocusLeft")
	expect(model.rows[0].candidate.detail == Prefix.key_label(KEY_H | KEY_MASK_ALT), "Unmenued actions show their shortcut too")
	host.free()
	fixture[0].free()

func test_prefix_keys_that_open_the_command_line() -> void:
	expect(Prefix.command_line_text(typed(58)) == "", "Typed : opens an empty line")
	expect(Prefix.command_line_text(typed(37, KEY_5, true)) == "%", "Typed % opens stable pane IDs directly")
	expect(Prefix.command_line_text(typed(0, KEY_PERCENT)) == "%", "KEY_PERCENT without unicode opens pane IDs")
	expect(Prefix.command_line_text(typed(0, KEY_5, true)) == "%", "Replayed Shift+5 opens pane IDs")
	expect(Prefix.command_line_text(typed(53, KEY_5, true)) == "5", "Layout text wins over Shift+5 fallback")
	expect(Prefix.command_line_text(typed(55, KEY_7)) == "7", "A typed digit opens number mode")
	expect(Prefix.command_line_text(typed(49, KEY_AMPERSAND, true)) == "1", "AZERTY's shifted digits count by character")
	expect(Prefix.command_line_text(typed(0, KEY_SEMICOLON, true)) == "", "Shift+; without unicode is :")
	expect(Prefix.command_line_text(typed(0, KEY_COLON)) == "", "KEY_COLON without unicode is :")
	expect(Prefix.command_line_text(typed(0, KEY_4)) == "4", "Replayed digits without unicode")
	expect(Prefix.command_line_text(typed(52, KEY_4, false, true)) == null, "Ctrl+digit is not typing")
	expect(Prefix.command_line_text(typed(104, KEY_H)) == null, "Letters stay prefix bindings")
	for spec in [["$", KEY_DOLLAR, KEY_4], ["@", KEY_AT, KEY_2]]:
		expect(Prefix.command_line_text(typed(str(spec[0]).unicode_at(0), KEY_UNKNOWN)) == spec[0], "Typed selector opens navigation, including Android IME")
		expect(Prefix.command_line_text(typed(0, spec[1])) == spec[0], "Symbol key without unicode opens navigation")
		expect(Prefix.command_line_text(typed(0, spec[2], true)) == spec[0], "Replayed shifted number opens navigation")
		expect(Prefix.command_line_text(typed(str(spec[0]).unicode_at(0), spec[1], false, true)) == null, "Ctrl-modified selector does not open navigation")

func test_dollar_lists_and_switches_live_sessions() -> void:
	var fixture := setup()
	var host: Node = fixture[1]
	var model: Model = fixture[2]
	var peer := SessionPeer.new()
	var backend := RemoteBackend.new()
	backend.connection = peer
	host.session_backend = backend
	model.set_text("$")
	expect(labels(model) == ["main  $1", "notes  $2", "work  $3"], "Dollar lists server sessions instead of menu commands or tabs")
	expect(row_for(model, "main  $1").candidate.checked, "Current session is checked")
	model.set_text("$work")
	expect(model.accepted().candidate.name == "$3", "Session name selects exact match")
	model.execute(model.accepted())
	expect(peer.calls == [["session_switch", {"name": "$3"}]], "Enter switches the current client to the selected session")
	model.set_text("$")
	model.select(1)
	peer.available_sessions.remove_at(1)
	model.refresh()
	expect(model.accepted().is_empty(), "A removed session cannot fall through to another choice")
	peer.connected = false
	model.set_text("$")
	expect(model.rows.is_empty(), "Disconnected server offers no stale session actions")
	peer.free()
	host.free()
	fixture[0].free()


func test_placeholder_tracks_last_tab_and_its_last_pane() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	expect(model.placeholder_text() == "command   ·   10 tab   ·   10.1 pane   ·   %id   ·   @id   ·   $session", "Hint uses the last tab's position, not its stable ID")
	host.workspace_layout.reorder(9, 9)
	expect("10.2 pane" in model.placeholder_text(), "Reordering counts the new last tab's panes, including hidden panes")
	host.workspace_layout.take_pane("%12")
	expect("10.1 pane" in model.placeholder_text(), "Closing a pane updates the last address")
	host.workspace_layout.tabs.clear()
	expect(model.placeholder_text() == "command   ·   %id   ·   @id   ·   $session", "Empty workspaces do not advertise a nonexistent target")
	host.free()
	fixture[0].free()


func test_dollar_supports_remote_server_and_session() -> void:
	var fixture := setup()
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	var local := SessionPeer.new()
	local.display_name = "This computer"
	var remote := SessionPeer.new()
	remote.display_name = "studio"
	remote.workspace = "$1"
	remote.available_sessions = [{"id": "$1", "name": "build", "automatic_name": null}, {"id": "$4", "name": "Automation", "automatic_name": null}]
	var multi := MultiConnection.new()
	multi.connections = [local, remote]
	multi.selected = local
	var backend := RemoteBackend.new()
	backend.connection = multi
	host.session_backend = backend
	host.menu_entries.append_array(preload("res://scenes/session/LiveSessionMenu.gd").entries(host))
	model.set_text("")
	expect(not labels(model).any(func(l): return str(l).begins_with("SwitchSession")), "Switch Session submenu entries do not pollute command mode")
	model.set_text("$")
	expect(labels(model).has("main  $1") and labels(model).has("studio/Automation  $4"), "Connected remote sessions appear with their server prefix")
	model.set_text("$studio/Automation")
	expect(model.accepted().candidate.peer == remote and model.accepted().candidate.name == "$4", "Server/name selects the remote session")
	model.set_text("$studio/4")
	expect(model.accepted().candidate.peer == remote and model.accepted().candidate.name == "$4", "Server/number selects the remote session ID")
	model.set_text("$studio/$4")
	expect(model.accepted().candidate.peer == remote and model.accepted().candidate.name == "$4", "Server/$ID selects the remote session ID")
	model.execute(model.accepted())
	expect(remote.calls == [["session_switch", {"name": "$4"}]], "Executing switches the remote server to the selected session")
	local.free()
	remote.free()
	multi.free()
	host.free()
	fixture[0].free()


func test_restore_checkpoint_command_and_parameters() -> void:
	if OS.has_feature("mobile"): return
	var fixture := setup()
	var app: App = fixture[0]
	var host: Host = fixture[1]
	var model: Model = fixture[2]
	var checkpoints := preload("res://scenes/Checkpoints.gd").new()
	var now := Time.get_unix_time_from_system()
	checkpoints.history = {
		"manual": [
			{"path": "/tmp/m1.json", "saved_at": now - 180, "windows": 2, "tabs": 4, "panes": 6},
			{"path": "/tmp/m2.json", "saved_at": now - 600, "windows": 1, "tabs": 2, "panes": 3},
		],
		"auto": [
			{"path": "/tmp/a1.json", "saved_at": now - 60, "windows": 5, "tabs": 6, "panes": 12},
			{"path": "/tmp/a2.json", "saved_at": now - 120, "windows": 5, "tabs": 6, "panes": 10},
		],
	}
	app.checkpoints = checkpoints
	host.menu_entries.append_array(checkpoints.menu_entries())
	model.set_text("")
	expect(not labels(model).any(func(l): return str(l).begins_with("ResumeAutoCheckpoint") or str(l).begins_with("ResumeManualCheckpoint")), "Individual checkpoint history entries do not become mangled command names")
	expect(labels(model).has("RestoreCheckpoint"), "A single RestoreCheckpoint command is listed")
	model.set_text("RestoreCheckpoint")
	model.execute(model.accepted())
	expect(host.restored == [["auto", "/tmp/a1.json"]], "RestoreCheckpoint with no arguments restores the latest checkpoint")
	host.restored.clear()
	model.set_text("RestoreCheckpoint ")
	expect(labels(model) == ["RestoreCheckpoint 1", "RestoreCheckpoint 2", "RestoreCheckpoint 3", "RestoreCheckpoint 4"], "Trailing space lists numbered checkpoints newest first")
	expect(model.rows[0].candidate.detail == "auto" and "12 panes" in model.rows[0].candidate.title, "Candidate rows keep the checkpoint description and tag in their columns")
	model.set_text("RestoreCheckpoint 2")
	model.execute(model.accepted())
	expect(host.restored == [["auto", "/tmp/a2.json"]], "RestoreCheckpoint 2 restores the 2nd latest checkpoint")
	host.restored.clear()
	model.set_text("RestoreCheckpoint manual")
	expect(labels(model) == ["RestoreCheckpoint manual 1", "RestoreCheckpoint manual 2"], "Tag filter lists checkpoints of that tag")
	model.execute(model.accepted())
	expect(host.restored == [["manual", "/tmp/m1.json"]], "RestoreCheckpoint manual defaults to 1 (latest manual)")
	host.restored.clear()
	model.set_text("RestoreCheckpoint --tag manual 2")
	model.execute(model.accepted())
	expect(host.restored == [["manual", "/tmp/m2.json"]], "RestoreCheckpoint --tag manual 2 restores the 2nd latest manual checkpoint")
	checkpoints.free()
	host.free()
	app.free()
