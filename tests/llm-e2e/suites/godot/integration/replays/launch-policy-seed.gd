extends "font-controls.gd"
const Defaults = preload("res://scenes/TerminalSessionDefaults.gd")

func policy_dialog() -> Node:
	await menu("Shell::Session Defaults…")
	await hold(.1)
	for child in host.get_children():
		if child is Defaults:return child
	return null

func new_policy_tab() -> bool:
	var old: int=host.active_session_id
	host.world.create_terminal_tab()
	if not await until(func():return host.active_session_id!=old and host.active_terminal()!=null and host.active_terminal().get_shell_pid()>0,"Future-policy tab owns a new live shell"):return false
	await camera_at_rest()
	terminal=host.active_terminal()
	return true

func output_line(marker: String) -> bool:
	return Array(str(terminal.get_text(false).text).split("\n")).any(func(line):return line.strip_edges()==marker)

func zero_image(name: String, reset: String) -> void:
	var marker:="ZERO_IMAGE_POLICY_"+name.to_upper()
	var content:="\u001b[2J\u001b[H\u001b[38;2;0;255;0m"+marker+"\u001b[0m\r\n\u001b_Ga=T,f=32,s=1,v=1,i=4729,c=8,r=4,q=2;/wAA/w==\u001b\\"
	var encoded:=Marshalls.raw_to_base64(content.to_utf8_buffer())
	var command:="[Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))" % encoded
	if reset=="whole":command="[Console]::Write(([char]27)+'c'); "+command
	elif reset=="split":command="[Console]::Write([char]27); [Console]::Out.Flush(); Start-Sleep -Milliseconds 150; [Console]::Write('c'); "+command
	await type(command+"{enter}")
	await until(func():return output_line(marker),"Real shell emits green identity for "+name)
	await hold(.3)
	check(terminal.image_placements().is_empty(),"Zero storage rejects red Kitty image after "+name)
	snap("zero-image-"+name)

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	connection=host.session_backend.connection
	var stop_effects: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var original: int=host.active_session_id
	var original_pid: int=terminal.get_shell_pid()
	var original_limits: Dictionary=connection.topology.panes[0].limits.duplicate(true)
	await type("Write-Output 'SEMANTIC_REAL_OUTPUT_152'{enter}")
	await until(func():return output_line("SEMANTIC_REAL_OUTPUT_152"),"Real integrated PowerShell command completes")
	await hold(.3)
	check(terminal.copy_last_output(),"Automatic PowerShell integration supplies semantic last output")
	var semantic: String=DisplayServer.clipboard_get()
	check(semantic.strip_edges()=="SEMANTIC_REAL_OUTPUT_152","Automatic semantic copy excludes command and prompt: "+JSON.stringify(semantic))
	var dialog:=await policy_dialog()
	dialog.limits.scrollback_bytes.edit.text="16777216"
	await dialog_click(dialog.get_ok_button())
	check(dialog.status.text=="Defaults applied to future local sessions.","Actual defaults form accepts byte history budget")
	dialog.canceled.emit()
	await process_frame
	if not await new_policy_tab():return
	var large: int=host.active_session_id
	await type("0..4999 | ForEach-Object { 'KEEP_{0:D4}' -f $_ }{enter}")
	await until(func():return output_line("KEEP_4999"),"Large-budget shell emits 5000 real lines",30)
	await hold(.5)
	var history: String=terminal.get_text(true).text
	check("KEEP_0000" in history and "KEEP_4999" in history,"Large budget retains first and last real output lines")
	FileAccess.open(directory.path_join("retained-history.txt"),FileAccess.WRITE).store_string(history)
	dialog=await policy_dialog()
	dialog.limits.scrollback_bytes.edit.text="0"
	dialog.limits.kitty_image_storage_mb.edit.text="0"
	dialog.integration.select(2)
	dialog.limits.scrollback_bytes.edit.grab_focus()
	await hold(.1)
	picture(host,"session-defaults-byte-policy")
	await dialog_click(dialog.get_ok_button())
	dialog.canceled.emit()
	await process_frame
	if not await new_policy_tab():return
	var zero: int=host.active_session_id
	await type("Write-Output 'NO_AUTOMATIC_SEMANTICS_152'{enter}")
	await until(func():return output_line("NO_AUTOMATIC_SEMANTICS_152"),"Integration-disabled PowerShell completes command")
	await hold(.2)
	check(not terminal.copy_last_output(),"Disabled integration produces no semantic command selection")
	await type("0..249 | ForEach-Object { 'ZERO_{0:D3}' -f $_ }{enter}")
	await until(func():return output_line("ZERO_249"),"Zero-budget shell produces scrolling output")
	terminal.scroll_to_row(0)
	await process_frame
	var scroll: Dictionary=terminal.get_ui_state()
	FileAccess.open(directory.path_join("zero-scroll-state.json"),FileAccess.WRITE).store_string(JSON.stringify(scroll,"  "))
	check(scroll.scroll_offset==0 and scroll.scroll_total==scroll.scroll_page,"Zero scrollback keeps actual viewport offset at zero with only the visible page")
	check("ZERO_000" not in str(terminal.get_text(true).text),"Zero history evicts old complete lines")
	await zero_image("initial","")
	await zero_image("whole-ris","whole")
	await zero_image("split-ris","split")
	var panes: Array=connection.topology.panes.duplicate(true)
	for pane in panes:
		if int(pane.id)==original:check(int(pane.pid)==original_pid and pane.limits==original_limits,"Future policies leave original PTY and resolved limits unchanged")
		if int(pane.id)==zero:check(pane.limits.scrollback_bytes==0 and pane.limits.kitty_image_storage_mb==0,"New zero policies appear in actual owner topology")
	FileAccess.open(directory.path_join("seed.json"),FileAccess.WRITE).store_string(JSON.stringify({"frontend_pid":OS.get_process_id(),"original":original,"large":large,"zero":zero,"panes":panes,"history_sha256":history.sha256_text(),"semantic_copy":semantic},"  "))
	stop_effects.call()
