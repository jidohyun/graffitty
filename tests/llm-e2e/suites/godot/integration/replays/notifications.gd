extends "terminal-tools.gd"
const BellSettings=preload("res://scenes/TerminalBellSettings.gd")
class Delivery extends "res://scenes/SystemNotifications.gd":
	var directory: String
	func _spawn_helper() -> Dictionary:
		return OS.execute_with_pipe(OS.get_environment("GRAFFITTY_INPUT_PYTHON"),["-u",ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_notification_delivery.py"),directory])

var service: Node
var bells := 0
var sounds := 0

func job(id: String) -> Dictionary:
	for pending in service.pending:
		if pending.request.id==id and not pending.get("closing",false):return pending
	return {}

func await_job(id: String) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	while job(id).is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	return job(id)

func await_empty() -> void:
	var deadline := Time.get_ticks_msec()+5000
	while not service.pending.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	check(service.pending.is_empty(),"Notification delivery completes")

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	var owner: int=host.active_session_id
	var pid: int=terminal.get_shell_pid()
	var old: Node=app.system_notifications
	service=Delivery.new()
	service.application=app
	service.directory=directory
	app.add_child(service)
	app.system_notifications=service
	old.queue_free()
	terminal.bell.connect(func():bells+=1)
	for child in terminal.get_children():
		if child.get_script()==preload("res://scenes/TerminalIntegrationUI.gd"):
			terminal.audible_bell_requested.disconnect(child._audible_bell)
	terminal.audible_bell_requested.connect(func():sounds+=1)
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	if not await command("\u001b]99;i=cap:p=?;\u001b\\\u001b[c\u001b[8;1H",Vector2i(0,7)):return
	if not await command("\u001b]99;i=notice:a=focus,report:c=1:d=0;완료 café\u001b\\\u001b]99;i=notice:p=body:d=0;Readable body\u001b\\\u001b]99;i=notice:p=buttons;Inspect\u2028Continue\u001b\\\u001b[9;1H",Vector2i(0,8)):return
	var first:=await await_job("notice")
	if not check(not first.is_empty(),"OSC99 assembles Unicode title/body/application buttons"):return
	var first_key: String=first.native_id
	if not await command("\u001b]99;i=alive:p=alive;\u001b\\\u001b[10;1H",Vector2i(0,9)):return
	host.world.create_terminal_tab()
	var deadline:=Time.get_ticks_msec()+10000
	while host.active_session_id==owner and Time.get_ticks_msec()<deadline:await process_frame
	var other: int=host.active_session_id
	await camera_at_rest()
	await menu("Edit::Terminal Bell…")
	var dialog: Node
	for child in host.get_children():
		if child is BellSettings:dialog=child
	if not check(dialog!=null,"Actual Terminal Bell menu opens controls"):return
	dialog.duration.text="-1"
	dialog.get_ok_button().pressed.emit()
	check("between" in dialog.status.text,"Invalid bell duration rejected")
	dialog.duration.text="1600"
	dialog.color.color=Color(1,0,0,.5)
	dialog.audible.button_pressed=true
	dialog.get_ok_button().pressed.emit()
	await hold(.15)
	check(dialog.status.text=="Bell preferences applied.","Bell preferences apply through actual controls")
	overlay.hide()
	capture("terminal-bell-dialog")
	dialog.canceled.emit()
	check(service.activate(first_key,2),"Native notification action activates without an in-app viewer")
	await await_empty()
	await camera_at_rest()
	check(host.active_session_id==owner and terminal.get_shell_pid()==pid,"Application action focuses original live pane")
	check(not service.activate(first_key,2),"Consumed notification key rejects repeated activation")
	if not await command("\u001b]99;i=replace:a=report;Old\u001b\\\u001b[11;1H",Vector2i(0,10)):return
	var replaced:=await await_job("replace")
	var old_key: String=replaced.native_id
	if not await command("\u001b]99;i=replace:a=report;New\u001b\\\u001b[12;1H",Vector2i(0,11)):return
	deadline=Time.get_ticks_msec()+5000
	while (job("replace").is_empty() or job("replace").native_id==old_key) and Time.get_ticks_msec()<deadline:await process_frame
	check(not service.activate(old_key),"Replacement rejects previous native key")
	service.dismiss(job("replace").native_id)
	await await_empty()
	if not await command("\u001b]99;i=expiry:a=report:c=1:w=100;Expires\u001b\\\u001b[13;1H",Vector2i(0,12)):return
	var expiring:=await await_job("expiry")
	var expired_key: String=expiring.get("native_id","")
	await hold(.25)
	await await_empty()
	check(not expired_key.is_empty() and not service.activate(expired_key),"Expired notification key rejects activation")
	if not await command("\u001b]99;i=close:c=1;Close me\u001b\\\u001b[14;1H",Vector2i(0,13)):return
	await await_job("close")
	if not await command("\u001b]99;i=close:p=close;\u001b\\\u001b[15;1H",Vector2i(0,14)):return
	await await_empty()
	if not await command("\u001b]9;OSC9 terminator is not bell\u0007\u001b[2J\u001b[2;1HBELL STABLE TEXT\u001b[?25l",Vector2i(-1,-1)):return
	await hold(.2)
	check(bells==0 and sounds==0,"BEL terminating OSC9 does not request visual or audible bell")
	for pending in service.pending:service.dismiss(pending.native_id)
	await await_empty()
	snap("bell-before")
	sequence+=1
	FileAccess.open(directory.path_join("phase-%d.vt" % sequence),FileAccess.WRITE).store_string("\u0007")
	deadline=Time.get_ticks_msec()+5000
	while bells==0 and Time.get_ticks_msec()<deadline:await process_frame
	snap("bell-peak")
	await hold(.35)
	snap("bell-middle")
	await hold(1.6)
	snap("bell-after")
	check(bells==1 and sounds==1,"Configured audible preference reaches delivery adapter exactly once without OS sound")
	host.sessions[other].term.send_text("[Console]::Write(([char]27)+']99;i=closed:a=report;closed'+([char]7));\r")
	var closing:=await await_job("closed")
	var closed_key: String=closing.get("native_id","")
	host._close_terminal_pane(other)
	deadline=Time.get_ticks_msec()+5000
	while host.sessions.has(other) and Time.get_ticks_msec()<deadline:await process_frame
	check(not closed_key.is_empty() and not service.activate(closed_key),"Closed-owner notification key cannot activate another pane")
	await await_empty()
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		var cap: String="\u001b]99;i=cap:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,icon,buttons,alive,close,?:s=system,silent,error,warn,warning,info,question:w=1:u=0,1,2\u001b\\"
		var replies: String="\u001b[?62;22c\u001b]99;i=alive:p=alive;notice\u001b\\\u001b]99;i=notice;2\u001b\\\u001b]99;i=notice:p=close;\u001b\\\u001b]99;i=expiry:p=close;\u001b\\\u001b]99;i=close:p=close;\u001b\\"
		check(receipt.text==cap+replies,"Exact capabilities precede DA1, alive/action/close replies; stale actions leak nothing: "+receipt.utf8_hex)
	release.call()
