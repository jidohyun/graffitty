extends "../../../../tests/llm-e2e/replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")

func prefix_key(key: String) -> void:
	await keys("ctrl+a")
	await keys(key)

func wait_panes(count: int) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while host.sessions.size() != count and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.sessions.size() == count, "Expected %d terminal panes" % count)
	await hold(0.3)

# Fyler's root title is a literal path; the header may elide its start.
func literal_root(view: Control, pane: String, id: int) -> bool:
	var title: String = host.session_model(id).title
	var shown: String = view.panes[pane].handle.text
	return title.is_absolute_path() and (shown == title or (shown.begins_with("…") and title.ends_with(shown.trim_prefix("…"))))

func play() -> void:
	await camera_at_rest()
	var source: String = host.pane_focus
	var source_id := int(source.substr(1))
	var view: Control = host.workspace_view
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = true
	var original: Dictionary = Layout.find(group.tree, source)
	original.rect = Rect2(view.content_rect().get_center() - Vector2(100, 130), Vector2(480, 300))
	view.refresh()
	# An unrelated pending operation used to starve the filetree for ten seconds.
	host.session_backend.pending_operations[999999] = true
	await prefix_key("tab")
	await wait_panes(2)
	host.session_backend.pending_operations.erase(999999)
	if host.sessions.size() != 2: return
	check(host.pane_focus == source, "Prefix Tab retains original focus on opening")
	# The bundled runtime has no install step: opening posts no setup notice.
	# (Notification cards and history are covered by notifications_smoke.gd.)
	await hold(1.0)
	check(host.application.notifications.history.is_empty(), "Bundled filetree opens without a setup notification")
	check(not host.diagnostic_panel.panel.visible, "Opening the bundled filetree reports no error")
	await prefix_key("tab")
	await wait_panes(1)
	var source_pane: Node = view.panes[source]
	source_pane.header.set_hovered(true)
	check(source_pane.header.has_part("filetree") and source_pane.header.view.last_error().is_empty(), "Filetree mod button has its icon")
	source_pane.header.view.click("filetree")
	await wait_panes(2)
	if host.sessions.size() != 2: return
	var filetree_id := -1
	for id in host.sessions:
		if id != source_id: filetree_id = id
	var filetree := "%%%d" % filetree_id
	check(host.pane_focus == filetree, "Filetree header button opens and focuses the connected filetree")
	check(view._chromium_owners().get(filetree) == source, "Filetree connects to original pane")
	check(view.pane_rects[filetree].position.x < view.pane_rects[source].position.x, "Filetree opens on the left")
	# Its initial rectangle overlaps the original by 40px. Physics must move it.
	await hold(1.5)
	check(not view.pane_rects[filetree].intersects(view.pane_rects[source]), "Force animation separates the floating filetree")
	check(view.chromium_links.edges.size() == 1, "Filetree ownership line is drawn")
	var file := OS.get_environment("GRAFFITTY_FILETREE_TEST_FILE")
	var reply: Dictionary = await host.session_backend.connection.remote_call(filetree_id, "filetree.open_file", {"path": file})
	check(not reply.has("error"), "File open creates viewer")
	await wait_panes(3)
	var viewer: String = reply.get("result", {}).get("pane", "")
	if viewer.is_empty(): return
	check(view._chromium_owners().get(viewer) == filetree, "Viewer connects to filetree")
	check(view.pane_rects[viewer].position.y < view.pane_rects[source].position.y, "Viewer opens above original pane")
	check(view.chromium_links.edges.size() == 2, "Both ownership lines are drawn")
	var language: Node = host.localization
	var original_language: String = language.choice
	language.set_language("ko", false)
	await hold(0.1)
	check(literal_root(view, filetree, filetree_id), "Filetree root path remains literal in Korean")
	check(view.panes[viewer].handle.text == "파일 뷰어", "File viewer title updates when the client language changes")
	language.set_language("ja", false)
	await hold(0.1)
	check(literal_root(view, filetree, filetree_id), "Filetree root path remains literal in Japanese")
	language.set_language(original_language, false)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_FILETREE_TEST_SCREENSHOT"))
	var chromium_reply: Dictionary = await host.session_backend.connection.remote_call(filetree_id, "filetree.open_file", {"path": file + ".html"})
	check(not chromium_reply.has("error"), "HTML opens in Chromium")
	var chromium_key: String = chromium_reply.get("result", {}).get("pane", "")
	var chromium_id := int(chromium_key.substr(1))
	var deadline := Time.get_ticks_msec() + 20000
	while (not host.chromiums.has(chromium_id) or host.chromiums[chromium_id].texture == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.chromiums.has(chromium_id), "Chromium viewer appears")
	if not host.chromiums.has(chromium_id): return
	var chromium: Node = host.chromiums[chromium_id]
	check(view._chromium_owners().get(chromium_key) == filetree, "Chromium connects to filetree")
	host.focus_pane(chromium_key)
	await chromium.request("cdp", {"method":"Runtime.evaluate", "params":{"expression":"document.querySelector('textarea').focus()"}})
	await prefix_key("a")
	await hold(0.5)
	var selection: Dictionary = await chromium.request("cdp", {"method":"Runtime.evaluate", "params":{"expression":"document.querySelector('textarea').selectionEnd - document.querySelector('textarea').selectionStart", "returnByValue":true}})
	check(selection.get("result", {}).get("result", {}).get("value", 0) == 17, "Prefix then A sends Select All to Chromium")
	var surfaces: Array = host.workspace_surfaces(filetree_id)
	check(surfaces.any(func(s): return s.kind == "terminal" and s.id == filetree), "Surface kinds identify terminal panes")
	check(surfaces.any(func(s): return s.kind == "chromium" and s.id == chromium_key), "Surface kinds identify Chromium panes")
	await prefix_key("tab")
	await wait_panes(2)
	check(host.pane_focus == source, "Closing filetree returns focus to original pane")
	check(host.sessions.has(int(viewer.substr(1))), "Closing filetree preserves its viewer")
	check(not view._chromium_owners().has(viewer), "Viewer becomes an independent pane")
	check(host.chromiums.has(chromium_id) and not view._chromium_owners().has(chromium_key), "Chromium remains open and detached")
	var detached: Dictionary = await chromium.request("chrome-state")
	check(not detached.has("error"), "Detached Chromium still accepts commands")
	check(view.chromium_links.edges.is_empty(), "Closing removes both ownership lines")
	await prefix_key("backspace")
	await wait_panes(3)
	check(host.pane_focus != source, "Prefix Backspace opens with filetree focus")
	await prefix_key("tab")
	await wait_panes(2)
	check(view.chromium_links.edges.is_empty(), "Closing removes ownership lines")
