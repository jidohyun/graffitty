extends SceneTree
## Copy mode takes Vim keys through the focused GUI route, including letters a
## Korean layout reports as jamo, and announces yanks through `copied`.
## godot --headless --path . --script tests/terminal_copy_mode_vi_smoke.gd

var failures := 0
var terminal: Control
var copies: Array[String] = []


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-vi-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")


func settle() -> void:
	await process_frame
	await process_frame


func push(keycode: Key, unicode: int, ctrl := false, shift := false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.unicode = unicode if down else 0
		event.ctrl_pressed = ctrl
		event.shift_pressed = shift
		event.pressed = down
		terminal.get_viewport().push_input(event)


## Vim keys by physical letter. `as_text` replaces the reported text, as an
## input method in Hangul mode does (`k` arrives as ㅏ).
func keys(sequence: String, as_text := "") -> void:
	for i in sequence.length():
		var c := sequence[i]
		var lower := c.to_lower()
		var code: Key = KEY_NONE
		if lower >= "a" and lower <= "z":
			code = (KEY_A + lower.unicode_at(0) - 97) as Key
		var text := as_text[i] if i < as_text.length() else c
		push(code, text.unicode_at(0), false, c != lower)
	await settle()


## Typed text with no keycode, like an input method's committed syllables.
func typed(text: String) -> void:
	for c in text:
		push(KEY_NONE, c.unicode_at(0))
	await settle()


func modal() -> String:
	return str(terminal.get_ui_state().get("modal", "?"))


func run() -> void:
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	var config := preload("res://graffitty/terminal_config.gd").new()
	config.apply_live(terminal)
	terminal.copied.connect(func(text): copies.append(text))
	terminal.grab_focus()
	await settle()
	terminal.remote_feed_stream("alpha beta.gamma\r\nsecond line\r\n".to_utf8_buffer(), 40, 6, false, false)
	await settle()

	check(terminal.perform_action("copy_mode"), "Copy mode opens")
	await keys("ggwviwy")
	check(copies == ["beta"], "gg w viw y copies the word")
	check(modal() == "", "y leaves copy mode")

	terminal.perform_action("copy_mode")
	await keys("kyy", "ㅏㅛㅛ")
	check(copies.back() == "second line", "Letters follow keycodes under a Hangul layout")

	terminal.perform_action("search")
	check(modal() == "search", "Search opens its prompt")
	push(KEY_X, 0)
	await typed("line")
	push(KEY_ENTER, 0)
	await settle()
	check(modal() == "copy_mode", "Enter accepts the search and stays in copy mode")
	await keys("ygn")
	check(copies.back() == "line", "An input method's swallowed key is not typed; ygn yanks the match")

	terminal.perform_action("copy_mode")
	await keys("gg")
	push(KEY_V, "v".unicode_at(0), true)
	await keys("jly")
	check(copies.back() == "al\nse", "Ctrl-V selects a block")

	terminal.perform_action("copy_mode")
	push(KEY_ESCAPE, 0)
	await settle()
	check(modal() == "", "Escape leaves copy mode")

	terminal.remote_feed_stream("\u001bcfoo-bar camelCase 한글 까치 가방\r\nfoo.bar foo+bar\r\n".to_utf8_buffer(), 40, 6, false, false)
	await settle()
	terminal.perform_action("copy_mode")
	await keys("ggyiw")
	check(copies.back() == "foo", "Default keyword characters split hyphens")
	config.iskeyword.append("-")
	check(config.copy().iskeyword == ["@", "48-57", "_", "192-255", "-"], "Copy word configuration survives cloning")
	var restored := preload("res://graffitty/terminal_config.gd").new()
	restored.overlay(config.to_config())
	check(restored.iskeyword == config.iskeyword, "Copy word configuration survives serialization")
	terminal.perform_action("copy_mode")
	config.apply_live(terminal)
	await keys("ggyiw")
	check(copies.back() == "foo-bar", "Configured hyphens are part of the word")
	terminal.perform_action("copy_mode")
	await keys("ggviwS\"")
	check(copies.back() == '"foo-bar"' and modal() == "", "Visual S quote wraps, copies, and exits")
	terminal.perform_action("copy_mode")
	await keys("ggviwS(")
	check(copies.back() == "( foo-bar )", "Opening bracket adds inner spaces")
	terminal.perform_action("copy_mode")
	await keys("ggviwS")
	push(KEY_ESCAPE, 0)
	await keys("y")
	check(copies.back() == "foo-bar", "Escape cancels wrapping while preserving the selection")
	config.iskeyword.append("^-")
	config.apply_live(terminal)
	terminal.perform_action("copy_mode")
	await keys("ggyiw")
	check(copies.back() == "foo", "An appended iskeyword exclusion overrides an earlier inclusion")
	config.iskeyword.erase("^-")
	var isolated_copy = config.copy()
	isolated_copy.iskeyword.append("^_")
	check(not "^_" in config.iskeyword, "Changing copied iskeyword rules does not mutate the original")
	config.apply_live(terminal)
	check(config.validate().is_empty(), "Full iskeyword configuration validates")
	isolated_copy.iskeyword.append("256")
	check(not isolated_copy.validate().is_empty(), "Invalid iskeyword range is rejected")
	terminal.perform_action("copy_mode")
	await keys("gg wyi w")
	check(copies.back() == "bar", "Space wordmotion and text objects split configured keywords")
	terminal.perform_action("copy_mode")
	await keys("ggw wyi w")
	check(copies.back() == "Case", "Space wordmotion splits camelCase")
	terminal.perform_action("copy_mode")
	# Matches r in foo-bar, then 글 in 한글, then 까 in 까치.
	await keys("gg3frviwy", "ㅎㅎ3ㄹㄱㅍㅑㅈㅛ")
	check(copies.back() == "까치", "Physical r finds Hangul initial ㄱ including tense ㄲ")
	terminal.perform_action("copy_mode")
	await keys("ggs")
	check(modal() == "search", "s opens a text prompt")
	check(terminal.get_ui_state().flash_active, "s activates the dim backdrop even before typing")
	await typed("한글")
	push(KEY_ENTER, 0)
	await keys("viwy")
	check(copies.back() == "한글", "s accepts committed Hangul and jumps to the match")
	terminal.perform_action("copy_mode")
	await keys("ggs")
	await typed("foo.")
	var labels: Array = terminal.get_ui_state().get("copy_labels", [])
	check(labels.size() == 1, "s exposes the visible jump label")
	if labels.size() == 1:
		check(labels[0].row == 1 and labels[0].column == 4, "Jump label follows the literal match")
		check(labels[0].label.to_lower() != "b", "Label cannot consume the next query character")
		await typed(labels[0].label)
	check(modal() == "copy_mode", "Typing a jump label accepts s search")
	await keys("yiW")
	check(copies.back() == "foo.bar", "Flash treats punctuation literally and jumps by label")
	terminal.perform_action("copy_mode")
	await keys("ggs")
	await typed("한")
	push(KEY_ESCAPE, 0)
	await settle()
	check(modal() == "copy_mode", "Escape cancels s without leaving copy mode")
	await keys("yiw")
	check(copies.back() == "foo-bar", "Cancelled s restores the original cursor")
	terminal.perform_action("copy_mode")
	await keys("ggs")
	await typed("없")
	check(modal() == "copy_mode" and not terminal.get_ui_state().flash_active, "No match immediately closes s and restores colors")
	await keys("yiw")
	check(copies.back() == "foo-bar", "Failed s restores the original cursor")

	terminal.perform_action("copy_mode")
	await keys("ggys")
	await typed("camel")
	var targets: Array = terminal.get_ui_state().get("copy_labels", [])
	check(targets.size() == 1, "ys opens flash")
	if targets.size() == 1:
		await typed(targets[0].label)
	check(copies.back() == "foo-bar", "ys yanks up to the flash target")
	terminal.perform_action("copy_mode")
	await keys("ggySiw]")
	check(copies.back() == "[foo-bar]", "ySiw] surrounds the word (the configured iskeyword has -)")
	terminal.perform_action("copy_mode")
	await keys("ggySS)")
	check(copies.back() == "(foo-bar camelCase 한글 까치 가방)", "ySS) surrounds the line")
	terminal.remote_feed_stream("\u001bc[Hello] <em>x</em>\r\n".to_utf8_buffer(), 40, 6, false, false)
	await settle()
	terminal.perform_action("copy_mode")
	await keys("ggcs]{")
	check(copies.back() == "{ Hello }", "cs]{ changes the brackets to spaced braces")
	terminal.perform_action("copy_mode")
	await keys("ggfxcst\"")
	check(copies.back() == "\"x\"", "cst\" replaces a tag with quotes")
	terminal.perform_action("copy_mode")
	await keys("ggVS<")
	check(modal() == "search", "A tag replacement takes typed text")
	await typed("p class=\"important\">")
	check(
		copies.back() == "<p class=\"important\">\n  [Hello] <em>x</em>\n</p>",
		"V S<p class=\"important\"> puts the tag on lines of its own",
	)
	check(terminal.remote_take_input().is_empty(), "Copy-mode keys never reach the program")
	terminal.queue_free()
	await settle()
	quit(1 if failures else 0)
