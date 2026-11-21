extends "res://videos/main-demo/recording/node-sessions/NodeSessionsDemo.gd"
## Bistro tour: nine sessions prepared off camera, one per Bistro place, then
## revealed only through real clicks in the compact Sessions sidebar.
##
## Every pane runs real work in the bistro-orders fixture repository. Agent
## panes are scripted playbacks whose shell steps execute in that repository.

const PORT := 8090
const BUILD_PROMPT := "Add evening reservations: POST /reservations seats a party at a free table for its time slot. Add tests and update the changelog."
const REVIEW_PROMPT := "Review the uncommitted reservations change before we ship 1.2.0."
const SPECIALS_PROMPT := "Write tonight's three specials for the menu board, one line each with a price."
const ORDER := ["Overview", "Server", "Claude", "Review", "Tests", "Menu page", "Agents", "Kitchen", "Release"]
const PLACES := ["cafe-awning", "terrace-tables", "dining-room", "bottle-shelves", "window-tables",
	"cafe-terrace", "square-reverse", "tree-square", "pharmacy-lane"]
## The tour's visiting order; ORDER is the creation order that assigns places.
const TOUR := ["Overview", "Menu page", "Server", "Kitchen", "Claude", "Review", "Tests", "Agents", "Release"]
## Seconds each arrival stays on screen before the pointer leaves for the next row.
const DWELL := 4.5
## The bundled CEF renderer aborts on a Blink DCHECK
## (LayerTreeView::AddPresentationCallback) about 62 s after it launches.
##
## Open the page just before capture and show it early, then record whether it
## died later off camera. Remove this once the CEF build is fixed.
const CHROMIUM_LIFETIME_S := 62.0

var agents_graph: Array = []
var menu_editor := ""
var menu_chromium_id := -1
var menu_chromium_opened_ms := 0
var visits: Array[Dictionary] = []


func select_demo_session(name: String) -> bool:
	if await super.select_demo_session(name): return true
	# Record why an arrival did not complete: which preparation gate held it.
	var world: Node = host.world
	var state := {"switching": host.session_switch_in_progress, "tab_fx_t": world.tab_fx_t,
		"preparing": world.tab_fx_preparing, "capture_pending": world._tab_fx_capture_pending,
		"stale": world.tab_fx_stale.size(), "floating": world._floating(),
		"layout_ready": host.session_backend.transition_layout_ready(host),
		"focus": host.pane_focus, "active_terminal": host.active_terminal() != null,
		"chromiums": host.chromiums.values().map(func(c): return {"texture": c.texture != null,
			"native": c.native_visible, "failure": c.failure_reason})}
	for i in 3:
		state["layout_frame_%d" % i] = str(world._tab_fx_layout_frame)
		await process_frame
	print("[tour] SWITCH STALLED ", JSON.stringify(state))
	return false


func run(key: String, text: String) -> void:
	host.sessions[int(key.substr(1))].term.send_text(text + "\r")


func split(key: String, direction: String) -> String:
	# Off-camera setup uses the real split control; the layout stays tiled.
	var added := await add_window(key, direction)
	if added.is_empty(): return ""
	await ready_shell(added)
	return added


func title(key: String, text: String) -> void:
	await host.set_pane_title(key, text)


func agent(key: String, provider: String, config: String, prompt: String, done: String) -> bool:
	FileAccess.open(output.path_join("launch-next"), FileAccess.WRITE).store_string(config)
	run(key, provider)
	if not await until(func(): return graph.nodes.get(key, {}).get("provider") == provider, provider + " playback registered: " + config): return false
	await hold(.5)
	if prompt.is_empty(): return true
	host.sessions[int(key.substr(1))].term.send_text(prompt)
	await hold(.3)
	host.sessions[int(key.substr(1))].term.send_text("\r")
	return await until(func(): return done in shell_text(key) and graph.nodes.get(key, {}).get("status") == "idle",
		config + " conversation completes", 60)


func new_session(name: String) -> String:
	if name == ORDER[0]:
		if not await demo_sessions.name_current(name): return ""
	elif not await demo_sessions.create(name): return ""
	var key: String = host.pane_focus
	await ready_shell(key)
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		await view_menu("Tiling")
	host.workspace_view.show_main()
	return key


func prepare_overview() -> bool:
	var shell := await new_session("Overview")
	if shell.is_empty(): return false
	run(shell, "git log --oneline --graph --decorate -6 && git status --short")
	if not await until(func(): return "?? tests/test_reservations.py" in shell_text(shell), "Overview shows history and the open change"): return false
	var before: int = host.sessions.size()
	await click(await on_header(shell, "filetree"))
	if not await until(func(): return host.sessions.size() == before + 1 and "README.md" in shell_text(host.pane_focus),
		"Filetree opens beside the Overview shell", 30): return false
	await title(shell, "git")
	return true


func prepare_server() -> bool:
	var server := await new_session("Server")
	if server.is_empty(): return false
	run(server, "python3 server.py")
	if not await until(func(): return "listening on http://localhost:%d" % PORT in shell_text(server), "The order server listens"): return false
	await title(server, "server.py")
	var menu := await split(server, "h")
	if menu.is_empty(): return false
	run(menu, "curl -s localhost:%d/menu | jq -c '.[] | {name, price}'" % PORT)
	if not await until(func(): return "Café crème" in shell_text(menu), "curl lists the menu"): return false
	await title(menu, "curl /menu")
	var rush := await split(menu, "v")
	if rush.is_empty(): return false
	run(rush, "python3 rush.py")
	if not await until(func(): return "order  #" in shell_text(rush) and "book " in shell_text(rush), "The dinner rush sends orders and bookings"): return false
	await title(rush, "rush.py")
	return true


func prepare_claude() -> bool:
	var key := await new_session("Claude")
	if key.is_empty(): return false
	return await agent(key, "claude", "build", BUILD_PROMPT, "CHANGELOG has a 1.2.0 entry")


func prepare_review() -> bool:
	var key := await new_session("Review")
	if key.is_empty(): return false
	var diff := await split(key, "h")
	if diff.is_empty(): return false
	run(diff, "git diff --color server.py")
	if not await until(func(): return "BOOK.reserve" in shell_text(diff), "The server diff is visible"): return false
	await title(diff, "git diff server.py")
	return await agent(key, "codex", "review", REVIEW_PROMPT, "Ready to ship.")


func prepare_tests() -> bool:
	var editor := await new_session("Tests")
	if editor.is_empty(): return false
	var tests := await split(editor, "h")
	if tests.is_empty(): return false
	run(editor, "nvim tests/test_reservations.py")
	run(tests, "python3 -m unittest -v")
	if not await until(func(): return "def test_first_free_table_is_assigned" in shell_text(editor), "Neovim opens the reservation tests"): return false
	if not await until(func(): return "Ran 12 tests" in shell_text(tests) and "OK" in shell_text(tests), "All twelve tests pass"): return false
	await title(editor, "test_reservations.py")
	await title(tests, "unittest")
	return true


func prepare_menu_page() -> bool:
	# Only the session: Chromium opens just before capture (CHROMIUM_LIFETIME_S).
	menu_editor = await new_session("Menu page")
	return not menu_editor.is_empty()


func open_menu_preview() -> bool:
	var editor := menu_editor
	var before: int = host.chromiums.size()
	run(editor, "gft chromium new --url http://localhost:%d/ --side right && nvim +/'<body>' '+normal! zt' +nohlsearch static/index.html" % PORT)
	if not await until(func(): return host.chromiums.size() == before + 1, "Chromium opens beside the editor", 40): return false
	menu_chromium_id = host.chromiums.keys()[-1]
	menu_chromium_opened_ms = Time.get_ticks_msec()
	if not await until(func(): return menu_chromium().texture != null, "Chromium renders the menu page", 30): return false
	if not await chromium_ready(menu_chromium(), "document.querySelectorAll('.dish').length >= 9 && document.querySelectorAll('.order').length > 0",
		"The live menu page lists dishes and the kitchen queue"): return false
	if not await until(func(): return "Kitchen queue" in shell_text(editor), "Neovim opens the menu page markup"): return false
	await title(editor, "index.html")
	# Opening Chromium focuses it; leave the session with the editor focused.
	await click(on(host.workspace_view.panes[editor].handle))
	host.focus_pane(editor)
	if not await until(func(): return host.pane_focus == editor and host.active_terminal() != null, "The editor keeps focus beside the menu page"): return false
	await snapshot("prepared-menu-preview")
	return true


## Session switches rebuild Chromium mirrors; the pane id is the stable identity.
func menu_chromium() -> Node:
	return host.chromiums.get(menu_chromium_id)


func menu_page_healthy(moment: String) -> bool:
	var page := menu_chromium()
	var healthy: bool = page != null and not page.page_crashed and page.failure_reason.is_empty()
	return check(healthy, "The menu page renderer is alive " + moment)


func prepare_agents() -> bool:
	var writer := await new_session("Agents")
	if writer.is_empty(): return false
	var checker := await split(writer, "h")
	if checker.is_empty(): return false
	if not await agent(writer, "claude", "specials", "", ""): return false
	if not await agent(checker, "codex", "allergens", "", ""): return false
	if not host.workspace_view.physics_enabled(): host.workspace_view.toggle_physics()
	await pinch_overview()
	await center_graph([writer, checker], 1)
	await wire(writer + "/turn_completed", checker + "/in")
	var ports = preload("res://scenes/GraphPorts.gd")
	var solid := false
	for edge in graph.edges.values():
		if ports.endpoint(edge, true) == writer + "/turn_completed":
			solid = host.workspace_view.agent_links.wire_pattern(edge) == "solid"
	if not check(solid, "Claude's completed turn feeds Codex over a solid wire"): return false
	host.sessions[int(writer.substr(1))].term.send_text(SPECIALS_PROMPT)
	await hold(.3)
	host.sessions[int(writer.substr(1))].term.send_text("\r")
	if not await until(func(): return "Clafoutis aux cerises, €9" in shell_text(writer), "Claude writes the specials", 60): return false
	if not await until(func(): return "print them as written" in shell_text(checker) and graph.nodes.get(checker, {}).get("status") == "idle",
		"Codex checks the delivered specials against the allergen sheet", 60): return false
	var delivered: bool = graph.receipts.any(func(receipt): return receipt.get("source") == writer and receipt.get("target") == checker and receipt.get("status") == "delivered")
	if not check(delivered, "The specials reached Codex through the graph"): return false
	agents_graph = [writer, checker]
	return true


func prepare_kitchen() -> bool:
	var board := await new_session("Kitchen")
	if board.is_empty(): return false
	var tickets := await split(board, "h")
	if tickets.is_empty(): return false
	run(board, "python3 board.py")
	run(tickets, "tail -n 30 -f logs/tickets.log")
	if not await until(func(): return "KITCHEN BOARD" in shell_text(board) and " × " in shell_text(tickets), "The kitchen board and ticket printer run"): return false
	await title(board, "board.py")
	await title(tickets, "tickets.log")
	return true


func prepare_release() -> bool:
	var release := await new_session("Release")
	if release.is_empty(): return false
	var notes := await split(release, "h")
	if notes.is_empty(): return false
	run(release, "./release.sh 1.2.0")
	run(notes, "bat CHANGELOG.md")
	if not await until(func(): return "bistro-orders-1.2.0 is ready to deploy" in shell_text(release), "The release builds a checksummed tarball", 30): return false
	if not await until(func(): return "Evening reservations" in shell_text(notes), "The changelog shows 1.2.0"): return false
	await title(release, "release.sh")
	await title(notes, "CHANGELOG.md")
	return true


func play() -> void:
	# Desktop DPI policy and pointer of the main demo's desktop recording.
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = maxf(1.0, DisplayServer.screen_get_scale(root.current_screen))
	root.size = Vector2i(2400, 1500)
	await hold(.3)
	var previous := overlay
	overlay = load("res://videos/shared/TilingPointer.gd").new()
	previous.get_parent().add_child(overlay)
	previous.queue_free()
	check(host.current_world_id() == "bistro", "The tour records Bistro World")
	await ready_shell(host.pane_focus)
	graph = host.agent_api.graph
	# Setup is off camera; restore the real effects before the first frame.
	var effects_enabled: bool = host.world.fx_enabled
	host.world.fx_enabled = false
	demo_sessions = preload("res://videos/shared/DemoSessions.gd").new(self)
	for step in [prepare_overview, prepare_server, prepare_claude, prepare_review, prepare_tests,
			prepare_menu_page, prepare_agents, prepare_kitchen, prepare_release]:
		if not await step.call() or not failures.is_empty():
			check(false, "Prepare " + str(step.get_method()))
			return
		await snapshot("prepared-" + str(step.get_method()).trim_prefix("prepare_"))
	var places: Array = ORDER.map(func(name): return demo_sessions.prepared[name].place)
	if not check(places == PLACES, "Every session has its own Bistro place: " + str(places)): return
	if not await demo_sessions.show_compact(): return
	if not await select_demo_session("Menu page"): return
	if not await open_menu_preview(): return
	if not await select_demo_session(TOUR[0]): return
	host.world.fx_enabled = effects_enabled
	overlay.pointer = root.get_visible_rect().size * Vector2(0.5, 0.62)
	await camera_at_rest()
	await hold(.5)
	beats.clear()
	typing_events.clear()
	settling.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await say("Overview")
	await hold(DWELL)
	await snapshot("tour-0-overview")
	var menu_window := {}
	for i in range(1, TOUR.size()):
		var name: String = TOUR[i]
		var start := movie_frame()
		if not await select_demo_session(name): return
		if name == "Agents":
			await frame_nodes(agents_graph, .9)
		await say(name + " arrived")
		if name == "Menu page":
			if not menu_page_healthy("on arrival"): return
			menu_window.arrived_s = (Time.get_ticks_msec() - menu_chromium_opened_ms) / 1000.0
		visits.append({"name": name, "start_frame": start, "arrived_frame": movie_frame(), "place": demo_sessions.prepared[name].place})
		await hold(DWELL)
		await snapshot("tour-%d-%s" % [i, name.to_lower().replace(" ", "-")])
		if name == "Menu page":
			if not menu_page_healthy("when the tour leaves it"): return
			menu_window.left_s = (Time.get_ticks_msec() - menu_chromium_opened_ms) / 1000.0
	await hold(1.0)
	await say("Finished")
	for name in ORDER:
		check(demo_sessions.retained(name), "Session survives the tour: " + name)
	# The page is off screen now, so its mirror may be gone; ask the server state.
	var crashed_later: bool = menu_chromium() != null and menu_chromium().page_crashed
	print("[tour] menu page renderer ", "crashed after leaving the screen" if crashed_later else "still alive", " at ",
		(Time.get_ticks_msec() - menu_chromium_opened_ms) / 1000.0, " s")
	FileAccess.open(output.path_join("tour.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"creation_order": ORDER, "tour": TOUR, "places": places, "visits": visits, "dwell_s": DWELL,
		"menu_page_renderer": {"on_screen_after_launch_s": menu_window, "frontend_saw_crash": crashed_later,
			"known_lifetime_s": CHROMIUM_LIFETIME_S}}, "\t"))
