extends "font-controls.gd"

# Pane creation/lifetime regression. GPU rendering is checked separately by
# chromium-window-close.gd; this case does not certify browser presentation.
func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var owner: int=host.active_session_id
	var owner_pid: int=host.active_terminal().get_shell_pid()
	var browser: Node=await host.create_chromium_session("about:blank")
	if not check(browser!=null,"Owner allocates browser surface"):return
	var browser_id: int=browser.session_id
	var original_tab: int=host.workspace_layout.containing("%%%d"%browser_id)
	var pane: Node=host.workspace_view.panes["%%%d"%browser_id]
	pane.title_menu.id_pressed.emit(7)
	if not await until(func():return host.workspace_layout.containing("%%%d"%browser_id)!=original_tab,"Browser moves alone into its own tab"):return
	var browser_tab: int=host.workspace_layout.containing("%%%d"%browser_id)
	host.create_terminal_window("%%%d"%browser_id)
	if not await until(func():return host.sessions.size()==2 and host.active_terminal()!=null and host.active_terminal().get_shell_pid()>0 and host.active_session_id!=owner,"Terminal starts beside browser source"):return
	var temporary: int=host.active_session_id
	check(host.workspace_layout.containing("%%%d"%temporary)==browser_tab,"New terminal joins browser tab instead of original owner tab")
	check(host.active_terminal().get_shell_pid()!=owner_pid,"New terminal owns an independent shell")
	host._close_terminal_pane(temporary)
	if not await until(func():return not host.sessions.has(temporary),"Temporary terminal closes"):return
	check(host.chromiums.has(browser_id) and host.workspace_layout.containing("%%%d"%browser_id)==browser_tab,"Temporary terminal close preserves browser surface and tab")
	check(host.sessions[owner].term.get_shell_pid()==owner_pid,"Original owner shell survives")
