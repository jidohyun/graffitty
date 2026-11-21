extends "../../../../replay/replay.gd"
## Overflowing tabs share authored world places and retain selection while scrolled.

func play() -> void:
	await open_tabs(1)
	if not await open_bistro(): return
	var world: Node = host.world
	host.instant_workspace_switch = true
	await open_tabs(maxi(26, world.authored_surface_count + 3))
	host.instant_workspace_switch = false
	await camera_at_rest()
	root.size = Vector2i(Vector2(960, 600) * root.content_scale_factor)
	root.content_scale_size = Vector2i(960, 600)
	await camera_at_rest()
	check(host.workspace_view.tab_bar.navigation.next_tabs.visible, "Narrow window exercises real tab overflow")
	var items: Array = host.get_tabs()
	var places := {}
	for surface in world.surfaces + world.spare_places:
		if surface.has_meta("place"): places[int(surface.get_meta("place"))] = surface.global_transform
	check(places.size() == world.authored_surface_count, "All authored Bistro places are retained")
	# Tabs exchange content on the wall in view instead of travelling, so which
	# tab holds which place follows the selection.
	#
	# Every tab still has a place, and tabs beyond the authored positions share
	# them in turn.
	var held := {}
	for i in items.size():
		var index: int = world._surface_for_session(int(items[i].id))
		var place := -1
		if index >= 0:
			for key in places:
				if world.surfaces[index].global_transform.is_equal_approx(places[key]): place = key
		check(place >= 0, "Tab %d stands at an authored Bistro position" % (i + 1))
		held[place] = int(held.get(place, 0)) + 1
	for key in places:
		var share := 0
		for i in items.size(): share += int(i % places.size() == key)
		check(int(held.get(key, 0)) == share, "Tabs beyond the authored positions share place %d in turn (%d of %d)" % [key, int(held.get(key, 0)), share])
	var viewed: Node = world.surfaces[world.active]
	var history: Array = []
	var geometry_changes: Array = []
	for button: Button in tab_strip().buttons.values():
		button.set_meta("resting_rect", Rect2(button.position, button.size))
		button.item_rect_changed.connect(func():
			var rect := Rect2(button.position, button.size)
			if not rect.is_equal_approx(button.get_meta("resting_rect")):
				geometry_changes.append(rect))
	host.ui_changed.connect(func():
		var state := [host.workspace_layout.active, host.active_session_id, tab_strip().selected_id]
		if history.is_empty() or history[-1] != state:
			history.append(state)
			print("OVERFLOW_SELECTION ", state))
	for index in [0, 23, 24, 25, 22]:
		var id: int = items[index].id
		# Reveal a tab as the arrow buttons would, without selecting it first.
		tab_strip()._ensure_tab_visible(id)
		await hold(0.3)
		await point_at(tab_grip(index))
		history.clear()
		geometry_changes.clear()
		await press()
		await release()
		await camera_at_rest()
		check(host.workspace_layout.active == id and host.active_session_id == id, "Click keeps tab %d selected in the workspace" % (index + 1))
		check(world.surfaces[world.active] == viewed and int(viewed.session_id) == id and world.term == host.sessions[id].term,
			"Tab %d is shown on the Bistro wall already in view" % (index + 1))
		check(history.all(func(state): return int(state[0]) == id), "Selection does not flicker to another tab while clicking %d" % (index + 1))
		check(tab_strip().selected_id == id and tab_strip().buttons[id].button_pressed, "Tab %d retains its selected appearance" % (index + 1))
		check(tab_strip().buttons[id].get_global_rect().intersection(tab_strip().get_global_rect()).size.x > 10, "Selected overflow tab remains visible")
		check(geometry_changes.is_empty(), "Selecting tab %d keeps every tab width and position fixed" % (index + 1))
		print("OVERFLOW_STATE ", index + 1, " ", history, " geometry_changes=", geometry_changes.size())
