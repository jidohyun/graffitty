extends SceneTree
## Re-record the real popup against the captured workspace's title snapshot.
## The film keeps its original moving terminals beneath this transparent layer.

var output := ""
var capture_path := ""
var preview_only := false
var viewport := SubViewport.new()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
		if arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
		if arg == "--preview-only": preview_only = true
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, output.path_join(kind.to_lower()))
	TranslationServer.set_locale("en_US")
	run.call_deferred()


func send_key(code: Key, unicode := 0) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode if pressed else 0
		event.pressed = pressed
		viewport.push_input(event)


func run() -> void:
	TranslationServer.set_locale("en_US")
	viewport.size = Vector2i(2400, 1500)
	viewport.size_2d_override = Vector2i(1200, 750)
	viewport.size_2d_override_stretch = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	# Initial viewport sizing emits size_changed; let it settle before opening
	# the production popup, which correctly closes when its viewport resizes.
	for i in 4: await process_frame
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(capture_path))
	var items: Array = meta.tabs_summary.items.duplicate(true)
	for item in items: item.pane_count = int(item.pane_count)
	# Preserve the resource sample shown by the original search, when available.
	for row in meta.tabs_summary.search.rows:
		if row.kind != "tab": continue
		for item in items:
			if item.id == row.id: item.resources = row.resources
	var source := Control.new()
	viewport.add_child(source)
	# The captured all-tabs button is at this logical window position.
	source.position = Vector2(81, 13)
	source.size = Vector2(28, 28)
	var popup := preload("res://scenes/TabMenu.gd").new()
	viewport.add_child(popup)
	# This offscreen component capture must survive desktop focus changes while
	# the user works. Its model, layout, input and drawing remain production UI.
	root.focus_exited.disconnect(popup.hide)
	popup.populate(items, int(meta.tabs_summary.active_tab), source, Color("20242c"))
	popup.show_below(source)
	for i in 4: await process_frame
	for character in "HTT":
		send_key(OS.find_keycode_from_string(character), character.unicode_at(0))
		await process_frame
	for i in 4: await process_frame
	var start := 0
	var end := 0
	var selected_at := 0
	for event in meta.typing_events:
		if event.text == "HTTP": start = int(event.key_frames[-1])
	for beat in meta.beats:
		# The beat is emitted before Escape; its frame still contains the menu.
		if beat.action == "Tabs: status summary complete": end = int(beat.frame) + 1
		if beat.action == "Tabs: matching panes visible": selected_at = int(beat.frame) - start - 10
	assert(end > start and selected_at > 0)
	send_key(KEY_P, "P".unicode_at(0))
	for frame in (1 if preview_only else end - start):
		if frame == selected_at: send_key(KEY_DOWN)
		await process_frame
		await RenderingServer.frame_post_draw
		assert(popup.is_visible_in_tree(), "Search capture must show the popup")
		var rendered := viewport.get_texture().get_image()
		assert(rendered.get_used_rect().has_area(), "Search capture must contain visible pixels")
		rendered.save_png(output.path_join("%04d.png" % frame))
	var rows: Array = popup.model.filter(items, "HTTP")
	var partial: Array = []
	for row in rows:
		if row.kind != "pane": continue
		var matched := ""
		for index in row.match_indices: matched += str(row.title)[index].to_upper()
		assert(not matched.is_empty())
		if matched != "HTTP": partial.append({"pane_key": row.pane_key, "title": row.title, "matched": matched})
	assert(not partial.is_empty(), "The recorded popup must include typo matches")
	var file := FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"source": capture_path, "start_frame": start, "end_frame": end,
		"selected_at": selected_at, "size": viewport.get_texture().get_image().get_size(),
		"popup_rect": popup.get_global_rect(), "rows": rows, "partial_matches": partial,
		"match_color": "#ffd078"}, "\t"))
	file.close()
	print("SEARCH_MENU_CAPTURE_PASS ", JSON.stringify(partial))
	quit()
