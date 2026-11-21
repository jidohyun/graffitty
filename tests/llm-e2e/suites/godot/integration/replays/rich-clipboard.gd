extends "input-routing.gd"
const IntegrationUI = preload("res://scenes/TerminalIntegrationUI.gd")
var directory: String
var terminal: Node
var integration: Node

func phase(number: int) -> void:
	FileAccess.open(directory.path_join("phase-%d.vt" % number), FileAccess.WRITE).store_string(FileAccess.get_file_as_string(directory.path_join("command-%d.vt" % number)))
	var marker := "PRIVATE_PHASE_%d_READY" % number
	var deadline := Time.get_ticks_msec() + 10000
	while marker not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(marker in str(terminal.get_text(false).text), "Real PTY emits clipboard phase %d" % number)
	await hold(.1)

func consent() -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while not is_instance_valid(integration.dialog) and Time.get_ticks_msec() < deadline:
		await process_frame
	return check(is_instance_valid(integration.dialog) and integration.dialog.visible, "Real clipboard read opens consent")

func consent_click(allow: bool) -> void:
	var button: Button = integration.dialog.get_ok_button() if allow else integration.dialog.get_cancel_button()
	# Embedded dialog controls are in their own Window coordinates.
	var at: Vector2 = Vector2(integration.dialog.position) + button.get_global_rect().get_center()
	await click(at)
	await process_frame
	check(not is_instance_valid(integration.dialog), "Pointer click answers clipboard consent")

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	host.session_backend.connection.acknowledged.connect(func(message):
		if message.type == "error": print("CLIPBOARD_OWNER_ERROR ", JSON.stringify(message)))
	host.session_backend.connection.clipboard_received.connect(func(id, event):
		print("CLIPBOARD_EVENT ", id, " ", event.type, " ", event.get("ticket", 0), " ", str(event.get("operation", {}).get("kind", ""))))
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	check(await host.set_pane_title("%%%d" % host.active_session_id, "Clipboard acceptance"), "Owner acknowledges the requesting pane title")
	for child in terminal.get_children():
		if child is IntegrationUI: integration = child
	if not check(integration != null, "Terminal owns its native consent handler"): return
	terminal.set("clipboard_read", 2)
	terminal.set("clipboard_write", true)
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw reader sends rich transfer and queries"):
		return
	var initial_bytes := int(FileAccess.get_file_as_string(directory.path_join("expected-initial-bytes")))
	var initial_deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < initial_deadline:
		if FileAccess.file_exists(directory.path_join("received-bytes")) and int(FileAccess.get_file_as_string(directory.path_join("received-bytes"))) >= initial_bytes: break
		await process_frame
	if not check(FileAccess.file_exists(directory.path_join("received-bytes")) and int(FileAccess.get_file_as_string(directory.path_join("received-bytes"))) == initial_bytes, "Initial rich transfer returns every expected byte before changing permissions"): return
	terminal.set("clipboard_read", 0)
	await phase(1)
	terminal.set("clipboard_write", false)
	await phase(2)
	terminal.set("clipboard_write", true)
	terminal.set("clipboard_read", 1)
	await phase(3)
	if not await consent(): return
	overlay.hide()
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("rich-clipboard-consent.png"))
	check("Clipboard acceptance" in integration.dialog.dialog_text, "Consent identifies requesting pane")
	await consent_click(false)
	await phase(4)
	if not await consent(): return
	await consent_click(true)
	await phase(5)
	if not await consent(): return
	var grid: Vector2i = terminal.get_grid_size()
	terminal.remote_feed_stream(PackedByteArray(), grid.x, grid.y, true, false)
	await process_frame
	await consent_click(true)
	await phase(6)
	check(not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY), "Windows reports no native primary selection; protocol must return ENOSYS")
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw reader records every clipboard reply"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		var expected := FileAccess.get_file_as_string(directory.path_join("expected.txt"))
		check(receipt.text == expected, "Exact Unicode, PNG, alias/enumeration, denial and consent bytes; stale checkpoint consent returns no data (%d bytes)" % receipt.text.length())
	check(terminal.get_shell_pid() == pid, "Rich transfer preserves original shell")
