extends "res://tests/unit/test_case.gd"
const Service := preload("res://scenes/AppNotifications.gd")

# A localized notice whose argument must stay literal.
func notice(service: Node, owner: Node, path: String, event_id := "") -> Dictionary:
	var source := "Server font download failed: %s"
	return service.post(tr("Rename Pane"), tr(source) % path, owner, "info", 12.0, event_id,
		{"title": "Rename Pane", "body": source, "args": [path]})

func test_history_keeps_dismissed_notices_and_literal_arguments() -> void:
	var service := Service.new()
	var owner := Node.new()
	var posted: Array = []
	service.posted.connect(func(entry): posted.append(entry))
	notice(service, owner, "~/.config/nvim Ω %s [b]/init.lua")
	expect(posted.size() == 1 and service.history.size() == 1, "A notice posts once and enters history")
	var entry: Dictionary = service.history[0]
	expect(entry.body == "Server font download failed: ~/.config/nvim Ω %s [b]/init.lua", "Arguments stay literal, including percent and markup characters")
	expect(entry.owner == owner.get_instance_id(), "The source window owns the toast")
	service.clear_history()
	expect(service.history.is_empty(), "Clearing history removes its entries")
	owner.free()
	service.free()

func test_shared_server_event_is_recorded_once_across_windows() -> void:
	var service := Service.new()
	var first := Node.new()
	var second := Node.new()
	notice(service, first, "~/.config/fonts", "same-server-event")
	notice(service, second, "~/.config/fonts", "same-server-event")
	expect(service.history.size() == 1, "Two windows receiving the same event share one history entry")
	notice(service, second, "~/.config/fonts", "later-event")
	expect(service.history.size() == 2, "A later event with the same text is a new notice")
	first.free()
	second.free()
	service.free()

func test_history_is_bounded_and_retains_newest_entries() -> void:
	var service := Service.new()
	for index in Service.MAX_HISTORY + 2: service.post("Notice", str(index), null)
	expect(service.history.size() == Service.MAX_HISTORY and service.history.front().body == "2", "Long-lived clients retain the latest 1000 notices")
	expect(service.history.back().id == Service.MAX_HISTORY + 2, "Notice identities stay unique when history rolls over")
	service.free()
