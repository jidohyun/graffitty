extends "res://videos/main-demo/recording/parallel/ParallelDemo.gd"
## Claude implements, Codex tests each build in its Chromium and sends
## failures back, until every E2E test passes.
##
## The edit starts at the "Loop start" beat; "Implement N", "Test N", "Result
## N" and "Done" beats drive its spotlight and signs.
const CLAUDE_PROMPT := "Build the sign-up page from spec.md"
const CODEX_PROMPT := "Test each build in Chromium and send failures to Claude."
const BUILDS := 5


func _initialize() -> void:
	super._initialize()
	# Current Flat 3D startup reports this engine warning before anything is
	# recorded; the panel is dismissed before capture. Every other diagnostic fails.
	diagnostic_guard.allow("Depth of field is not supported in viewports with a transparent background. Disabling DoF in transparent viewport.",
		"res://llm-e2e/replay/background.gd", 109, true)
	# Readable terminal text after the window is fitted into the 1080p frame.
	var file := FileAccess.open(preload("res://config/UserConfig.gd").config_path(), FileAccess.READ_WRITE)
	file.seek_end()
	file.store_string("\n[terminal]\nfont_size = 20\n")
	file.close()


func status(key: String) -> String:
	return str(graph.nodes.get(key, {}).get("status", ""))


func take_file(name: String) -> String:
	return output.path_join(name)


func passes(build: int) -> int:
	var results = JSON.parse_string(FileAccess.get_file_as_string(take_file("results-%d.json" % build)))
	return (results as Array).filter(func(result): return result.passed).size() if results is Array else -1


## Setup before capture: deliver the line directly instead of animating typing.
func send_line(key: String, text: String) -> void:
	host.focus_pane(key)
	host.sessions[int(key.substr(1))].term.send_text(text + "\r")
	await hold(.3)


## Workspace layout outside Main View, where graph ports and ownership lines
## are drawn: Claude on the left; Codex bottom right, leaving room above it.
const ORIGIN := Vector2(0, 2200)
## Codex is at its terminal's minimum size for this font; Chromium takes its size above it.
const CLAUDE_SIZE := Vector2(1000, 1400)
const CODEX_OFFSET := Vector2(1250, 708)
const CODEX_SIZE := Vector2(1132, 692)
var claude_key := ""
var codex_key := ""


## Drag the real corner grip; a zoomed-out first grab can miss it, so retry.
func resize(key: String, size: Vector2) -> void:
	var view: Control = host.workspace_view
	for attempt in 3:
		var rect: Rect2 = view.pane_rects[key]
		if rect.size.distance_to(size) < 20: return
		await frame_rect(rect.merge(Rect2(rect.position, size)))
		var inset := Vector2(6, 6) / maxf(view.navigation_zoom, .25)
		await drag(view.window_point(rect.end - inset), view.window_point(rect.position + size - inset), .4)
		await owner_at_rest()


## Both agents plus the space above Codex where its Chromium opens.
func overview(seconds := .45) -> void:
	var rects: Dictionary = host.workspace_view.pane_rects
	var codex: Rect2 = rects[codex_key]
	await frame_rect(rects[claude_key].merge(codex).merge(Rect2(codex.position - Vector2(0, codex.size.y + 8), codex.size)), seconds)


func prepare_loop() -> Dictionary:
	var view: Control = host.workspace_view
	graph = host.agent_api.graph
	var claude: String = host.pane_focus
	await ready_shell(claude)
	# Split at Main View's zoom: zoomed out, compact headers hide their buttons.
	var codex := await create_beside(claude)
	if codex.is_empty(): return {}
	await pinch_overview()
	await move_to(claude, ORIGIN)
	await resize(claude, CLAUDE_SIZE)
	await move_to(codex, ORIGIN + CODEX_OFFSET)
	await resize(codex, CODEX_SIZE)
	await ready_shell(codex)
	claude_key = claude
	codex_key = codex
	check(view.pane_rects[claude].size.distance_to(CLAUDE_SIZE) < 80 and view.pane_rects[codex].size.distance_to(CODEX_SIZE) < 80,
		"Panes reach their layout sizes: %s %s" % [view.pane_rects[claude], view.pane_rects[codex]])
	var commands: Dictionary = live_settings() if live() else {"claude": "claude", "codex": "codex"}
	await send_line(claude, commands.claude)
	await send_line(codex, commands.codex)
	if not await until(func(): return graph.nodes.get(claude, {}).get("provider") == "claude" and graph.nodes.get(codex, {}).get("provider") == "codex",
		"Claude and Codex register as graph nodes", 120 if live() else 20): return {}
	# Agents run on the movie clock: their turns only progress while recording.
	host.diagnostic_panel.dismiss_messages()
	await camera_at_rest()
	await overview()
	return {"claude": claude, "codex": codex}


## With the movie clock running (agents only progress then); cut from the edit.
func open_browser(claude: String, codex: String) -> String:
	var view: Control = host.workspace_view
	var chromiums: Array = host.chromiums.keys()
	await send_line(codex, CODEX_PROMPT)
	if not await until(func(): return host.chromiums.size() == chromiums.size() + 1, "Codex opens its Chromium", 30): return ""
	var chromium_id := 0
	for id in host.chromiums:
		if id not in chromiums: chromium_id = id
	var chromium_key := "%%%d" % chromium_id
	check(host.chromiums[chromium_id].tab_id == int(codex.substr(1)), "The Chromium belongs to Codex")
	if not await chromium_ready(host.chromiums[chromium_id], "document.body.textContent.includes('Waiting for the first build')", "Chromium shows the app placeholder"): return ""
	if not await until(func(): return "Ready." in shell_text(codex) and status(codex) == "idle", "Codex is ready before the first build", 30): return ""
	var rects: Dictionary = view.pane_rects
	check(view.chromium_links.edges.size() == 1, "The ownership line connects Codex and its Chromium")
	check(rects[chromium_key].end.y <= rects[codex].position.y + 1 and rects[chromium_key].position.x > rects[claude].end.x - 1,
		"Chromium sits above Codex, right of Claude: %s %s %s" % [rects[claude], rects[chromium_key], rects[codex]])
	return chromium_key


## Pane rectangles in footage pixels, for the edit's spotlight and signs.
func save_layout(panes: Dictionary) -> void:
	var view: Control = host.workspace_view
	var scale := root.content_scale_factor
	var layout := {"size": [root.size.x, root.size.y], "ui_scale": scale}
	for name in panes:
		var rect: Rect2 = view.pane_rects[panes[name]]
		var a: Vector2 = view.window_point(rect.position) * scale
		var b: Vector2 = view.window_point(rect.end) * scale
		layout[name] = [a.x, a.y, b.x - a.x, b.y - a.y]
	FileAccess.open(take_file("layout.json"), FileAccess.WRITE).store_string(JSON.stringify(layout, "\t"))


func play() -> void:
	# The desktop DPI policy gives the recorded chrome native proportions.
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = maxf(1.0, DisplayServer.screen_get_scale(root.current_screen))
	root.size = Vector2i(2400, 1500)
	await hold(0.3)
	var panes := await prepare_loop()
	if panes.is_empty(): return
	var claude: String = panes.claude
	var codex: String = panes.codex
	await wire(claude + "/turn_completed", codex + "/in")
	await wire(codex + "/send", claude + "/in")
	for edge in graph.edges.values():
		var expected := "dashed" if str(edge.from) == codex else "solid"
		check(host.workspace_view.agent_links.wire_pattern(edge) == expected, "%s → %s wire is %s" % [edge.from, edge.to, expected])
	await overview()
	overlay.pointer = Vector2(-200, -200)
	if live():
		await live_loop(claude, codex)
		return
	beats.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	var chromium := await open_browser(claude, codex)
	if chromium.is_empty(): return
	var lens: Vector4 = host.world.proj_rect
	await send_line(claude, CLAUDE_PROMPT)
	if not await until(func(): return status(claude) == "busy", "Claude starts build 1", 30): return
	check(lens.distance_to(host.world.proj_rect) < .001 * maxf(lens.z, .00001), "The camera holds the overview through setup")
	await say("Loop start")
	save_layout({"claude": claude, "codex": codex, "chromium": chromium})
	await snapshot("01-loop-start")
	for build in range(1, BUILDS + 1):
		if build > 1:
			if not await until(func(): return status(claude) == "busy", "Claude starts build %d" % build, 60): return
		await say("Implement %d" % build)
		if not await until(func(): return status(claude) == "idle", "Claude finishes build %d" % build, 60): return
		if not await until(func(): return status(codex) == "busy", "Codex receives build %d" % build, 30): return
		await say("Test %d" % build)
		if not await until(func(): return FileAccess.file_exists(take_file("results-%d.json" % build)), "E2E finishes on build %d" % build, 60): return
		await say("Result %d %d" % [build, passes(build)])
		await snapshot("build-%d-tested" % build)
		if build < BUILDS:
			if not await until(func(): return FileAccess.file_exists(take_file("sent-%d.json" % build)), "Codex sends build %d failures" % build, 30): return
	if not await until(func(): return status(codex) == "idle", "Codex finishes the last run", 30): return
	check(passes(BUILDS) == 6, "The final build passes every E2E test")
	await hold(1.5)
	check(status(claude) == "idle" and not FileAccess.file_exists(take_file("sent-%d.json" % BUILDS)), "Nothing is sent after the passing build")
	await say("Done")
	await snapshot("02-final")
	await hold(1.5)


## --live (live.py): the same scenario with real Claude Code and Codex, in real
## time and without a movie, to compare their behavior and formats with the mocks.
func live() -> bool:
	return "--live" in OS.get_cmdline_user_args()


func live_settings() -> Dictionary:
	return JSON.parse_string(OS.get_environment("E2E_LOOP_LIVE"))


func name_finished(turns: Dictionary, previous: Dictionary, name: String) -> bool:
	return turns[name] >= 1 and previous[name] != "busy"


## A real TUI takes a prompt as pasted text, then Enter.
func send_prompt(key: String, text: String) -> void:
	host.focus_pane(key)
	var term: Node = host.sessions[int(key.substr(1))].term
	term.paste_text(text)
	await hold(.8)
	term.send_text("\r")
	await hold(.5)


func live_loop(claude: String, codex: String) -> void:
	var minutes := float(live_settings().get("minutes", 25))
	var before: Array = host.chromiums.keys()
	await send_prompt(codex, CODEX_PROMPT)
	await say("Live: Codex instructed")
	await until(func(): return status(codex) == "busy", "Codex starts on its instruction", 120)
	await until(func(): return status(codex) == "idle", "Codex finishes its setup turn", 600)
	await snapshot("live-01-codex-ready")
	await send_prompt(claude, CLAUDE_PROMPT)
	await say("Live: Claude prompted")
	var names := {"claude": claude, "codex": codex}
	var turns := {"claude": 0, "codex": 0}
	# Count completed turns: a prompt can already have made an agent busy.
	var previous := {"claude": "idle", "codex": "idle"}
	var deadline := Time.get_ticks_msec() + int(minutes * 60000)
	var quiet_since := -1
	var claude_done := -1
	var log := FileAccess.open(take_file("live-status.jsonl"), FileAccess.WRITE)
	var logged := 0
	while Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() - logged > 2000:
			logged = Time.get_ticks_msec()
			log.store_line(JSON.stringify({"ms": logged, "claude": graph.nodes.get(claude, {}), "codex": graph.nodes.get(codex, {})}))
			log.flush()
		for name in names:
			var now := status(names[name])
			if now == "busy" and previous[name] != "busy":
				await say("Live: %s busy" % name)
			elif now != "busy" and previous[name] == "busy":
				turns[name] += 1
				await say("Live: %s finished turn %d" % [name, turns[name]])
				await snapshot("live-%s-%d" % [name, turns[name]])
			previous[name] = now
		if name_finished(turns, previous, "claude") and turns.codex == 0 and previous.codex != "busy":
			if claude_done < 0: claude_done = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - claude_done > 180000:
				await say("Live: Codex never started after Claude's build")
				break
		var settled: bool = turns.claude >= 1 and turns.codex >= 1 and previous.claude != "busy" and previous.codex != "busy"
		if not settled:
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - quiet_since > 60000:
			break
		await hold(.5)
	var opened: Array = host.chromiums.keys().filter(func(id): return id not in before)
	var evidence := {"turns": turns, "statuses": previous, "timed_out": Time.get_ticks_msec() >= deadline,
		"chromiums_opened_by_codex": opened.filter(func(id): return host.chromiums[id].tab_id == int(codex.substr(1))).size(),
		"edges": graph.edges, "claude": shell_text(claude), "codex": shell_text(codex)}
	FileAccess.open(take_file("live.json"), FileAccess.WRITE).store_string(JSON.stringify(evidence, "\t"))
	await snapshot("live-final")
