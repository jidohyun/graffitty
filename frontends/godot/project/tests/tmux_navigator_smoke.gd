extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"

var socket := ""
var strokes := 0

func tm(args: Array) -> String:
	var output := []
	var result := OS.execute("tmux", PackedStringArray(["-S", socket] + args), output, true)
	if result != 0: check(false, "tmux command fails: %s: %s" % [args, output])
	return str(output[0]).strip_edges() if not output.is_empty() else ""

func until(predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not predicate.call() and Time.get_ticks_msec() < deadline: await process_frame
	check(predicate.call(), "Navigation reaches the expected destination")

func play() -> void:
	await camera_at_rest()
	var source: String = host.pane_focus
	var other := await add_window(source, "h")
	if other.is_empty(): return
	host.focus_pane(source)
	await hold(.3)
	socket = "/tmp/gft-nav-godot-%d.sock" % OS.get_process_id()
	await type("tmux -S '%s' -f /dev/null new-session -s nav /bin/sh" % socket)
	await keys("enter")
	await hold(.5)
	var plugin := ProjectSettings.globalize_path("res://../../../integrations/tmux-graffitty/graffitty.tmux")
	tm(["run-shell", "'" + plugin + "'"])
	tm(["set-option", "-g", "default-shell", "/bin/sh"])
	# Match the person's existing server, including extended keyboard input.
	tm(["set-option", "-s", "extended-keys", "always"])
	tm(["set-option", "-s", "extended-keys-format", "csi-u"])
	var left := tm(["display-message", "-p", "-t", "nav", "#{pane_id}"])
	var right := tm(["split-window", "-h", "-P", "-F", "#{pane_id}"])
	await hold(.3)
	host.sessions[int(source.substr(1))].term.keystroke.connect(func(_cell, _unicode): strokes += 1)
	await keys("ctrl+h")
	await until(func(): return tm(["display-message", "-p", "-t", "nav", "#{pane_id}"]) == left)
	check(host.pane_focus == source, "Moving inside tmux stays in its Graffitty pane")
	await keys("ctrl+l")
	await until(func(): return tm(["display-message", "-p", "-t", "nav", "#{pane_id}"]) == right)
	await keys("ctrl+l")
	await until(func(): return host.pane_focus == other)
	check(strokes == 0, "tmux navigation does not emit typing effects")
	await keys("ctrl+h")
	await until(func(): return host.pane_focus == source)
	tm(["kill-server"])
