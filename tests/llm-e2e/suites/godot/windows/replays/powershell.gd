extends "../../../../replay/replay.gd"
## Real server PTY and production keyboard route, independently for each shell.
var expected_version := "7."

func text() -> String:
	return str(host.sessions[host.active_session_id].term.get_text(false).get("text", ""))

func expect_output(value: String, description: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while value not in text() and Time.get_ticks_msec() < deadline:
		await process_frame
	var found := value in text()
	check(found, description)
	if not found: print("[windows terminal] ", text())
	return found

func play() -> void:
	check(OS.get_name() == "Windows", "Native Windows desktop")
	if OS.get_name() != "Windows": return
	await say("Verify the actual PowerShell version and a live prompt")
	await type("Write-Output ('VERSION=' + $PSVersionTable.PSVersion.ToString()){enter}")
	if not await expect_output("VERSION=" + expected_version, "The requested PowerShell version responds"): return
	var id: int = host.active_session_id
	var pid: int = host.sessions[id].term.get_shell_pid()
	check(pid > 0, "The production server owns a real shell process")
	await say("Render Korean, non-ASCII symbols and a cwd containing spaces")
	var directory := OS.get_environment("XDG_STATE_HOME").path_join("한글 space % #")
	DirAccess.make_dir_recursive_absolute(directory)
	var quoted := directory.replace("'", "''")
	await type("Set-Location -LiteralPath '%s'{enter}" % quoted)
	await type("Write-Output ('CWD=' + (Get-Location).Path){enter}")
	if not await expect_output("CWD=" + directory.replace("/", "\\"), "PowerShell enters the exact Unicode directory"): return
	await type("Write-Output ('UNICODE=' + '한글 Ω 😀'){enter}")
	if not await expect_output("UNICODE=한글 Ω 😀", "Unicode output survives the real PTY"): return
	await type("& { Write-Output ('BLOCK=' + 'OK') }{enter}")
	if not await expect_output("BLOCK=OK", "Literal braces execute a real PowerShell script block"): return
	await type("Write-Output ({enter}'MULTILINE=' +{enter}'EDITX")
	await keys("backspace")
	await type("ED'){enter}")
	if not await expect_output("MULTILINE=EDITED", "Multiline input and Backspace editing produce the exact output"): return
	check(text().count("MULTILINE=EDITED") == 1, "The multiline command executes once")
	await say("Terminal color discovery must not alter mock prompt text")
	var scenario := OS.get_environment("XDG_STATE_HOME").path_join("palette-query.json")
	FileAccess.open(scenario, FileAccess.WRITE).store_string(JSON.stringify({
		"think_ms": 0, "char_ms": 0, "response": "UNMATCHED_PROMPT",
		"turns": [{"prompt": "palette probe", "response": "MOCK_QUERY_REPLY_OK"}],
	}))
	# No palette override: exercise the real Windows console palette adapter.
	# OSC10/11 support itself is covered by the separate ConPTY replay.
	await type("& $env:GRAFFITTY_BIN dev claude-mock --config '%s'{enter}" % scenario.replace("'", "''"))
	if not await expect_output("? for shortcuts", "The mock starts with native terminal color discovery"): return
	await type("palette probe{enter}")
	if not await expect_output("MOCK_QUERY_REPLY_OK", "Color replies do not contaminate the exact mock prompt"): return
	await keys("ctrl+c")
	await type("Write-Output ('MOCK=' + 'EXITED'){enter}")
	if not await expect_output("MOCK=EXITED", "The mock exits back to the original shell"): return
	await say("Interrupt foreground work and keep the same shell")
	await type("Start-Sleep -Seconds 30{enter}")
	await hold(1.0)
	await keys("ctrl+c")
	await type("Write-Output ('AFTER=' + 'INTERRUPT'){enter}")
	await expect_output("AFTER=INTERRUPT", "Ctrl+C interrupts foreground work and the next command runs")
	check(host.sessions[id].term.get_shell_pid() == pid, "Interrupt preserves the shell PID")
	await camera_at_rest()
	await RenderingServer.frame_post_draw
	if DisplayServer.get_name() != "headless":
		var screenshot := OS.get_environment("XDG_STATE_HOME").get_base_dir().path_join("powershell.png")
		root.get_texture().get_image().save_png(screenshot)
		print("[windows evidence] ", screenshot)
