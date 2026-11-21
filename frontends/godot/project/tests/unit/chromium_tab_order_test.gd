extends "res://tests/unit/test_case.gd"
## The pane's tab strip keeps a dropped tab's preview until the owner reports
## the same order. Page ids follow pages, so that report confirms the move.


func titles(strip: Control) -> Array:
	return strip._visual_order.map(func(id): return strip.buttons[id].get_meta("title"))


func test_a_dropped_tab_stays_where_it_was_dropped_once_the_owner_confirms() -> void:
	var strip: Control = preload("res://scenes/ChromiumTabStrip.gd").new()
	strip.reconcile([{"id": 1, "title": "A"}, {"id": 2, "title": "B"}, {"id": 3, "title": "C"}], 1)
	# What commit_drag leaves after dropping A at the end.
	strip._visual_order = [2, 3, 1]
	strip._pending_order = [2, 3, 1]
	strip.reconcile([{"id": 2, "title": "B"}, {"id": 3, "title": "C"}, {"id": 1, "title": "A"}], 1)
	expect(titles(strip) == ["B", "C", "A"], "The confirmed order is displayed: %s" % [titles(strip)])
	expect(strip._pending_order.is_empty(), "The owner's report confirms the preview at once")
	expect(strip.buttons[1].button_pressed, "The moved tab stays selected")
	strip.free()


func test_a_report_from_before_the_move_keeps_the_preview() -> void:
	var strip: Control = preload("res://scenes/ChromiumTabStrip.gd").new()
	strip.reconcile([{"id": 1, "title": "A"}, {"id": 2, "title": "B"}], 1)
	strip._visual_order = [2, 1]
	strip._pending_order = [2, 1]
	# A state sent before the owner applied the move must not undo the drop.
	strip.reconcile([{"id": 1, "title": "A"}, {"id": 2, "title": "B"}], 1)
	expect(titles(strip) == ["B", "A"], "The dropped order stays displayed: %s" % [titles(strip)])
	strip.free()
