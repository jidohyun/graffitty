extends "res://videos/main-demo/recording/tiling/RecordTilingDemo.gd"
## The tmux-send.nvim demo, recorded for graffitty.nvim: Neovim sends code and
## file paths to real Graffitty panes with the README's mappings.
##
## Each scene is prepared off camera in a fresh tab; only the demonstration
## itself is filmed.
const SCENES := ["ipython", "bash", "neovim", "fyler", "tabs"]
# Pacing for a README video: time to read each result, a visible selection
# before it is sent, and a title held at each scene's start and end.
const READ := 1.8
const SELECTED := 0.5
const START := 1.4
const END := 2.8
var scenes: Array[Dictionary] = []
var sends: Array[Dictionary] = []
var only_scene := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			only_scene = arg.trim_prefix("--scene=")
	super._initialize()


func check(ok: bool, message: String) -> bool:
	# Verification is recorded as metadata, not viewer-facing toasts.
	print("[graffitty.nvim demo] ", "PASS " if ok else "FAIL ", message)
	if not ok: failures.append(message)
	return ok


## Neovim panes run on the host, where graffitty.nvim reaches `gft`; REPLs and
## plain shells run in the Podman image. shell.sh reads this before starting.
func next_pane(kind: String) -> void:
	var file := FileAccess.open(output.path_join("next-pane"), FileAccess.WRITE)
	file.store_string(kind)
	file.close()


func added_key(before: Array) -> String:
	for id in host.sessions:
		if id not in before: return "%%%d" % id
	return ""


func open_tab(kind: String) -> String:
	next_pane(kind)
	var before: Array = host.sessions.keys()
	host.create_session()
	if not await until(func(): return not added_key(before).is_empty(), "A fresh tab opens"): return ""
	var key := added_key(before)
	await ready_shell(key)
	return key


func split(key: String, kind: String) -> String:
	next_pane(kind)
	host.focus_pane(key)
	var added := await add_window(key)
	if added.is_empty(): return ""
	await ready_shell(added)
	return added


func run(key: String, command: String) -> void:
	host.sessions[int(key.substr(1))].term.send_text(command + "\r")


func close_tab(id: int) -> void:
	host._close_group(id)
	await until(func(): return host.workspace_layout.tab(id).is_empty(), "The previous scene's tab closes")


## A fresh two-pane tab replaces the previous scene's tab, so every scene shows
## one tab whose panes are numbered .1 (left) and .2 (right).
func scene_tab(left_kind: String, left_command: String, right_kind: String, right_command: String) -> Array:
	var previous: int = host.workspace_layout.active
	var left := await open_tab(left_kind)
	if left.is_empty(): return []
	var right := await split(left, right_kind)
	if right.is_empty(): return []
	run(left, left_command)
	run(right, right_command)
	await close_tab(previous)
	return [left, right]


## Names panes with Rename Pane, using the README's .N pane numbers, so each
## header shows which count reaches it. The tab gets its own name.
func name_panes(tab: String, names: Dictionary) -> void:
	for key in names:
		check(await host.set_pane_title(key, names[key]), "Pane named " + names[key])
	var first: String = names.keys()[0]
	var reply = await app.agent_api.dispatch(int(first.substr(1)), "tab.set_title", {"title": tab})
	check(reply is Dictionary and not reply.has("error"), "Tab named " + tab)


func record_scene(name: String, title: String, keyboard_only := true) -> bool:
	await camera_at_rest()
	await hold(0.3)
	# Never film over an app message, such as a startup GPU warning.
	if not check(host.application.notifications.history.is_empty(), "No app messages are on screen before filming " + name):
		await snapshot("messages-before-" + name)
		return false
	if keyboard_only:
		# Hiding the drawn pointer alone leaves the last split button hovered.
		# Move the real replay pointer away before starting the movie clock.
		await point_at(Vector2(-100, -100), .01)
		await process_frame
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	scenes.append({"name": name, "title": title, "start_frame": movie_frame()})
	await say("Scene: " + name)
	await snapshot("%s-start" % name)
	return true


func end_scene() -> void:
	await snapshot("%s-end" % scenes[-1].name)
	scenes[-1].end_frame = movie_frame()
	await say("Scene end: " + scenes[-1].name)
	Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	capture_active = false


## Vim motions are single keys at a steady, readable pace.
func vim(motions: String, gap := 0.18) -> void:
	for ch in motions:
		_send_key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0), {"shift": ch != ch.to_lower()})
		await hold(gap)


## A count and graffitty.nvim's send key, typed like a person; the composition
## shows these keys with the main demo's keycaps.
func send(keys_text: String, label: String) -> void:
	await human_text(keys_text)
	sends.append({"keys": keys_text, "label": label, "key_frames": typing_events[-1].key_frames,
		"scene": scenes[-1].name})


func enter() -> void:
	_send_key(KEY_ENTER, 0, {})


## Terminal text without soft wraps: long paths span rows in a narrow pane.
func flat(key: String) -> String:
	return shell_text(key).replace("\n", "")


func cwd(key: String) -> String:
	return str(host.sessions[int(key.substr(1))].term.get_ui_state().get("cwd", "")).trim_suffix("/")


func scene_ipython() -> void:
	var panes := await scene_tab("host", "clear && exec nvim program.py", "podman", "clear && exec ipython3 --no-banner")
	if panes.is_empty(): return
	var editor: String = panes[0]
	var repl: String = panes[1]
	if not await until(func(): return "import numpy as np" in shell_text(editor), "Neovim opens the Python program"): return
	if not await until(func(): return "In [1]:" in shell_text(repl), "IPython is ready", 40.0): return
	await name_panes("graffitty.nvim", {editor: ".1 Neovim", repl: ".2 IPython"})
	host.focus_pane(editor)
	if not await record_scene("ipython", "IPython: execute your code interactively"): return
	await hold(START)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "In [2]:" in shell_text(repl), "IPython runs the import"): return
	await hold(READ)
	# Include the blank line after main(): it ends the block, as in a REPL.
	await vim("jj")
	await vim("V")
	await vim("jjj")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "In [3]:" in shell_text(repl), "IPython defines main()"): return
	await hold(READ)
	await vim("G")
	await send("2-", "Send to pane 2")
	if not await until(func(): return "Hello World 3!" in shell_text(repl) and "In [4]:" in shell_text(repl), "main() prints in IPython"): return
	await hold(READ)
	await vim("kkkkk")
	await vim("V")
	await vim("jj")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "In [5]:" in shell_text(repl), "IPython adds the two random arrays"): return
	await hold(READ)
	await vim("j")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "In [6]:" in shell_text(repl), "IPython reassigns a"): return
	await hold(READ)
	await vim("k")
	await send("2-", "Send to pane 2")
	if not await until(func(): return "In [7]:" in shell_text(repl), "IPython prints the new sum"): return
	await hold(END)
	await end_scene()


func scene_bash() -> void:
	var panes := await scene_tab("host", "clear && exec nvim +3 some_bash_script.sh", "podman",
		"clear && exec env PS1='\\w $ ' bash --noprofile --norc")
	if panes.is_empty(): return
	var editor: String = panes[0]
	var shell: String = panes[1]
	if not await until(func(): return "for i in {1..10}" in shell_text(editor), "Neovim opens the shell script"): return
	if not await until(func(): return shell_text(shell).strip_edges().ends_with("$"), "bash is ready"): return
	await name_panes("graffitty.nvim", {editor: ".1 Neovim", shell: ".2 bash"})
	host.focus_pane(editor)
	if not await record_scene("bash", "bash: run shell scripts too"): return
	await hold(START)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "\nHello World\n" in shell_text(shell), "bash runs the echo"): return
	await hold(READ)
	await vim("jj")
	await vim("V")
	await vim("jjj")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "Hello World 10" in shell_text(shell), "bash runs the loop"): return
	await hold(END)
	await end_scene()


func scene_neovim() -> void:
	var panes := await scene_tab("host", "clear && exec nvim program.py", "host", "clear && exec nvim +3 another.py")
	if panes.is_empty(): return
	var source: String = panes[0]
	var target: String = panes[1]
	if not await until(func(): return "import numpy as np" in shell_text(source), "Neovim opens the Python program"): return
	if not await until(func(): return "plt.show()" in shell_text(target), "The second Neovim opens another.py"): return
	await name_panes("graffitty.nvim", {source: ".1 Neovim", target: ".2 Neovim"})
	host.focus_pane(source)
	if not await record_scene("neovim", "Neovim: copy code to another Neovim"): return
	await hold(START)
	# Each block takes its trailing blank line, so pasted code keeps its spacing.
	await vim("V")
	await vim("j")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "import numpy as np" in shell_text(target), "The import lands in the other Neovim"): return
	await hold(READ)
	await vim("j")
	await vim("V")
	await vim("jjj")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "def main():" in shell_text(target), "main() keeps its indentation"): return
	await hold(READ)
	await vim("j")
	await vim("V")
	await vim("jjjjj")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "if __name__" in shell_text(target), "The main block lands below"): return
	await hold(READ)
	await vim("j")
	await hold(SELECTED)
	await send("2-", "Send to pane 2")
	if not await until(func(): return shell_text(target).count("main()") >= 2, "The call to main() completes the program"): return
	await hold(END)
	await end_scene()


func scene_fyler() -> void:
	var view: Control = host.workspace_view
	var panes := await scene_tab("host", "clear && exec nvim .", "host", "clear")
	if panes.is_empty(): return
	var tree: String = panes[0]
	var shell: String = panes[1]
	if not await until(func(): return "project" in shell_text(tree) and "some_bash_script.sh" in shell_text(tree), "Fyler lists the project"): return
	if not await until(func(): return shell_text(shell).strip_edges().ends_with("$"), "zsh is ready"): return
	await name_panes("graffitty.nvim", {tree: ".1 Fyler", shell: ".2 zsh"})
	host.focus_pane(tree)
	if not await record_scene("fyler", "nvim-tree, neo-tree, oil, fyler: send file paths", false): return
	await hold(START)
	await open_file_with_mouse(tree, "project")
	if not await until(func(): return "dataset_configs" in shell_text(tree), "Double-click expands the project"): return
	await hold(0.4)
	await open_file_with_mouse(tree, "dataset_configs")
	if not await until(func(): return "ch_greyflow" in shell_text(tree), "Double-click expands dataset_configs"): return
	await hold(0.5)
	# zsh's AUTO_CD enters each directory path sent with Enter.
	await send("2-", "Send to pane 2")
	if not await until(func(): return cwd(shell).ends_with("/project/dataset_configs"), "Sending a directory changes the shell directory"): return
	await hold(READ)
	for name in ["ch_greyflow", "ch_image", "project", "dataset_configs"]:
		await click(file_point(tree, name))
		await hold(0.25)
		await send("2-", "Send to pane 2")
		if not await until(func(): return cwd(shell).ends_with("/" + name), "The shell enters " + name): return
		await hold(READ)
	await click(on(view.panes[shell].body, Vector2(0.5, 0.8)))
	await hold(0.2)
	await human_text("vi ")
	await hold(0.3)
	await click(file_point(tree, "cater_task1.py"))
	await hold(0.25)
	await send("2-", "Send to pane 2")
	if not await until(func(): return "num_classes = 14" in shell_text(shell), "vi opens the sent file"): return
	await hold(READ)
	await click(on(view.panes[shell].body, Vector2(0.5, 0.8)))
	await hold(0.2)
	await human_text(":q")
	await hold(0.12)
	enter()
	if not await until(func(): return not "num_classes = 14" in shell_text(shell), "vi quits back to zsh"): return
	await hold(0.5)
	await human_text("vimdiff ")
	await hold(0.3)
	await click(file_point(tree, "cater_task1.py"))
	await hold(0.25)
	await send("2_", "Send to pane 2 without Enter")
	if not await until(func(): return "cater_task1.py'" in flat(shell), "The first path waits on the command line"): return
	await hold(0.5)
	await click(file_point(tree, "cater_task2.py"))
	await hold(0.25)
	await send("2_", "Send to pane 2 without Enter")
	if not await until(func(): return "cater_task2.py'" in flat(shell), "The second path waits on the command line"): return
	await hold(0.6)
	await click(on(view.panes[shell].body, Vector2(0.5, 0.8)))
	await hold(0.2)
	enter()
	if not await until(func(): return "num_classes = 14" in shell_text(shell) and "num_classes = 301" in shell_text(shell), "vimdiff compares both files"): return
	await hold(END)
	await end_scene()


func scene_tabs() -> void:
	var previous: int = host.workspace_layout.active
	var tree := await open_tab("host")
	if tree.is_empty(): return
	var editor := await split(tree, "host")
	if editor.is_empty(): return
	run(tree, "clear && exec nvim .")
	run(editor, "clear && exec nvim +3 some_bash_script.sh")
	# A background tab keeps its last picture: let tab 1 draw before tab 2 opens.
	if not await until(func(): return "project" in shell_text(tree), "Fyler lists the project in tab 1"): return
	if not await until(func(): return "for i in {1..10}" in shell_text(editor), "Neovim opens the shell script in tab 1"): return
	host.focus_pane(editor)
	# Panes .1 and .2 split the left half; the receiving pane .3 keeps the right half.
	var python := await open_tab("podman")
	if python.is_empty(): return
	var target := await split(python, "podman")
	if target.is_empty(): return
	var job := await split(python, "podman")
	if job.is_empty(): return
	run(python, "clear && exec ipython3 --no-banner")
	run(job, "clear")
	run(job, "# Some job is running here")
	run(job, "sleep 10000")
	run(target, "clear")
	run(target, "# I want the script to run here.")
	await close_tab(previous)
	await name_panes("editor", {tree: ".1 Fyler", editor: ".2 Neovim"})
	await name_panes("jobs", {python: ".1 IPython", job: ".2 sleep", target: ".3 zsh"})
	if not await until(func(): return "In [1]:" in shell_text(python), "IPython is ready", 40.0): return
	host.sessions[int(python.substr(1))].term.send_text("import my_project")
	if not await until(func(): return "I want the script to run here." in shell_text(target), "Tab 2 pane 3 is waiting"): return
	check(host.get_tabs().size() == 2 and host.workspace_layout.active == int(host.get_tabs()[1].id),
		"The scene starts on tab 2 of two tabs")
	if not await record_scene("tabs", "Tabs: send to another tab", false): return
	await hold(START)
	await select_tab(0)
	await camera_at_rest()
	if host.pane_focus != editor:
		await click(on(host.workspace_view.panes[editor].handle))
	check(host.pane_focus == editor, "Tab 1's script Neovim has focus")
	await hold(0.6)
	await vim("V")
	await vim("jjjjj")
	await hold(SELECTED)
	await send("23-", "Send to tab 2, pane 3")
	await hold(0.6)
	await select_tab(1)
	await camera_at_rest()
	if not await until(func(): return "Hello World 10" in shell_text(target), "The script ran in tab 2 pane 3"): return
	await hold(END)
	await end_scene()


## Typing otherwise bends the sheet into a saddle, ripples and drifts it, so
## every glyph moves. Sparks remain. A still picture reads better and keeps
## the README GIF small.
func keep_sheet_still() -> void:
	var cfg = host.world.fx_cfg
	var active := str(cfg.behavior.active_state)
	cfg.set_option("scene.sheet", "typing_shape", "flat")
	cfg.set_option("state." + active, "sheet.ripple", 0.0)
	cfg.set_option("state." + active, "camera.drift_px", 0.0)
	var typing: Dictionary = cfg.frame(active)
	check(typing["sheet.shape"] == "flat" and is_zero_approx(float(typing["sheet.curvature_deg"]))
		and is_zero_approx(float(typing["sheet.ripple"])) and is_zero_approx(float(typing["camera.drift_px"])),
		"Typing keeps the sheet flat and still")


func play() -> void:
	# Use the desktop DPI policy so the recorded chrome has native proportions.
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = maxf(1.0, DisplayServer.screen_get_scale(root.current_screen))
	root.size = Vector2i(2400, 1500)
	await hold(0.3)
	var previous := overlay
	overlay = load("res://videos/shared/TilingPointer.gd").new()
	previous.get_parent().add_child(overlay)
	previous.queue_free()
	await ready_shell(host.pane_focus)
	check(host.world.terminal_config.font_size == 18, "The demo's larger terminal font is applied")
	host.workspace_view.show_main()
	# Typing would zoom and tilt the camera; keep every pane still and readable.
	hold_full_view()
	keep_sheet_still()
	await RenderingServer.frame_post_draw
	var canvas := root.get_texture().get_image().get_size()
	check(canvas == Vector2i(2400, 1500), "Movie canvas fits the native UI: %s" % canvas)
	capture_active = false
	Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	for name in SCENES:
		if not only_scene.is_empty() and name != only_scene: continue
		match name:
			"ipython": await scene_ipython()
			"bash": await scene_bash()
			"neovim": await scene_neovim()
			"fyler": await scene_fyler()
			"tabs": await scene_tabs()
		if not failures.is_empty(): return


func finish() -> void:
	var file := FileAccess.open(output.path_join("demo.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"scenes": scenes, "sends": sends, "fps": 60,
		"size": [2400, 1500], "scale": root.get_final_transform().get_scale().x}, "\t"))
	file.close()
	await super.finish()
