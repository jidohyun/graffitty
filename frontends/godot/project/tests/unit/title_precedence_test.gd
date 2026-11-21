extends "res://tests/unit/test_case.gd"

func test_pane_update_batch_refreshes_shared_controls_once() -> void:
	var host = load("res://scenes/TerminalHost.gd").new()
	var refreshes := [0]
	host.ui_changed.connect(func(): refreshes[0] += 1)
	for pane in 6: host._on_session_changed()
	expect(refreshes[0] == 0, "Shared controls wait for the complete pane batch")
	host._flush_session_ui()
	host._flush_session_ui()
	expect(refreshes[0] == 1, "Six pane updates produce one shared refresh")
	host._on_session_changed()
	host._flush_session_ui()
	expect(refreshes[0] == 2, "A later batch still refreshes the controls")
	host.free()

func test_owner_title_survives_raw_checkpoint_and_pin_changes() -> void:
	var model = load("res://scenes/TerminalSession.gd").new()
	model.set_owner_title("D:/workspace")
	model._on_title("관리자: raw console startup")
	expect(model.title == "D:/workspace", "Owner normalization wins over a raw checkpoint title")
	model.pin_title("Pinned")
	model.set_owner_title("Editor")
	expect(model.title == "Pinned", "Owner updates do not replace a presentation pin")
	model.pin_title("")
	expect(model.title == "Editor", "Clearing the pin restores the current owner title")
	model.set_owner_title("")
	expect(model.title == "", "An empty owner title does not revive raw startup decoration")
	model.free()

func test_pane_title_precedence_and_clearing() -> void:
	var model = load("res://scenes/TerminalSession.gd").new()
	model.initial_directory = "/workspace/start"
	expect(model.title == "/workspace/start", "An unset title uses the starting directory")
	model._state = {"cwd":"file://localhost/workspace/two%20words", "title":""}
	expect(model.title == "/workspace/two words", "OSC 7 paths are decoded")
	model._on_title("shell@remote: editor")
	expect(model.title == "shell@remote: editor", "Reported titles remain verbatim")
	model.pin_title("Pinned")
	model._on_title("new program")
	expect(model.title == "Pinned", "An explicit pane name overrides program titles")
	model.pin_title("")
	expect(model.title == "new program", "Clearing the explicit name restores the latest program title")
	model._on_title("")
	expect(model.title == "/workspace/two words", "Clearing OSC title restores the latest path")
	model.free()

func test_untitled_panes_use_tab_local_numbers_and_stable_ids() -> void:
	var host = load("res://scenes/TerminalHost.gd").new()
	var first = load("res://scenes/TerminalSession.gd").new()
	var second = load("res://scenes/TerminalSession.gd").new()
	host.sessions = {0: {"model": first}, 7: {"model": second}}
	host.workspace_layout.add(0, {"windows": [{"pane": "%0"}, {"pane": "%7"}]})
	expect(host.pane_title("%0") == ".1 (%0)", "First untitled pane uses its local number and stable ID")
	expect(host.pane_title("%7") == ".2 (%7)", "Pane number is not the stable ID plus one")
	second._on_title("%7")
	second.title_is_fallback = true
	expect(host.pane_title("%7") == ".2 (%7)", "Remote fallback IDs receive the local pane number")
	host.workspace_layout.tab(0).tree = {"windows": [{"pane": "%7"}, {"pane": "%0"}]}
	expect(host.pane_title("%7") == ".1 (%7)", "Numbers follow current layout order")
	second.title_is_fallback = false
	second._on_title("Terminal 7")
	expect(host.pane_title("%7") == "Terminal 7", "An explicitly reported title stays literal")
	second._on_title("")
	second.initial_directory = "/home/demo"
	expect(host.pane_title("%7") == "/home/demo", "Working directory takes precedence over the number")
	first.free()
	second.free()
	host.free()
