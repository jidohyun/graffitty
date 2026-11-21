extends "../../../../replay/replay.gd"
var evidence := ""
var pane_key := ""
var observations: Array = []

func comparable(value: String, phase: String) -> String:
	return value.replace("\\", "/").trim_suffix("/") if phase in ["startup", "cleared"] else value

func shell(command: String) -> void:
	host.active_terminal().send_text(command + "\r")

func title_is(expected: String, phase: String) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	var pane: Control = host.workspace_view.panes[pane_key]
	while (comparable(host.pane_title(pane_key), phase) != comparable(expected, phase) or comparable(pane.handle.text, phase) != comparable(expected, phase)) and Time.get_ticks_msec() < deadline:
		await process_frame
	var actual: String = host.pane_title(pane_key)
	var metadata: Array = host.session_backend.connection.topology.panes.filter(func(item): return int(item.id) == int(pane_key.substr(1)))
	var owner_title := str(metadata[0].title) if not metadata.is_empty() else ""
	check(comparable(owner_title, phase) == comparable(expected, phase), phase + ": session owner publishes the expected title")
	check(comparable(actual, phase) == comparable(expected, phase), phase + ": frontend title is " + expected + "; got " + actual)
	check(comparable(pane.handle.text, phase) == comparable(expected, phase), phase + ": visible pane header has the same title")
	RenderingServer.force_draw(false)
	var shot := phase + ".png"
	root.get_texture().get_image().save_png(evidence.path_join(shot))
	observations.append({"phase": phase, "expected": expected, "owner": owner_title, "frontend": actual, "header": pane.handle.text, "capture": shot})

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	pane_key = host.pane_focus
	var id: int = host.active_session_id
	var pid: int = host.active_terminal().get_shell_pid()
	var receipt := evidence.path_join("shell.json")
	var quoted := receipt.replace("'", "''")
	shell("@{cwd=(Get-Location).Path; version=$PSVersionTable.PSVersion.ToString(); elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath '%s.tmp'; Move-Item -LiteralPath '%s.tmp' -Destination '%s'" % [quoted, quoted, quoted])
	var deadline := Time.get_ticks_msec() + 15000
	while not FileAccess.file_exists(receipt) and Time.get_ticks_msec() < deadline: await process_frame
	if not check(FileAccess.file_exists(receipt), "Real PowerShell reports its cwd, version and elevation"): return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(receipt).trim_prefix("\ufeff"))
	check(bool(data.elevated) == (OS.get_environment("GRAFFITTY_TEST_ELEVATED") == "1"), "Shell elevation matches the required token")
	check(str(data.version).begins_with(OS.get_environment("GRAFFITTY_TEST_PS_VERSION")), "Requested PowerShell version runs")
	await title_is(str(data.cwd), "startup")
	shell("[Console]::Title = 'Win32 title Ω'")
	await title_is("Win32 title Ω", "win32")
	shell("[Console]::Write(([char]27).ToString() + ']2;OSC title 한글' + [char]7)")
	await title_is("OSC title 한글", "osc")
	await host.session_backend.connection.remote_call(id, "window.set_title", {"title": "Pinned title"})
	await title_is("Pinned title", "pinned")
	shell("[Console]::Title = 'Underlying title'")
	await hold(.3)
	await title_is("Pinned title", "pin-retained")
	await host.session_backend.connection.remote_call(id, "window.set_title", {"title": ""})
	await title_is("Underlying title", "unpinned")
	shell("[Console]::Title = ''")
	await title_is(str(data.cwd), "cleared")
	check(host.active_terminal().get_shell_pid() == pid, "All title changes preserve the original shell PID")
	FileAccess.open(evidence.path_join("titles.json"), FileAccess.WRITE).store_string(JSON.stringify({"shell": data, "observations": observations}))
