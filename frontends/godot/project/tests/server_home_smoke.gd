extends SceneTree
## Real layout, popup and navigation checks; no server or credential-store access.
class Home extends "res://scenes/remote/RemoteManager.gd":
	var activated_keys: Array[String] = []
	var removed_keys: Array[String] = []
	var starts := 0
	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		chooser.scroll_through_controls = true
		chooser.max_content_width = 1000
		add_child(chooser)
		_build_home()
		add_child(dialog)
		dialog.hide()
	func _update_landing_status() -> void:
		super._update_landing_status()
		# Fixture connections have no network transport, but the preview should
		# show a count consistent with the states it is exercising.
		landing_status.text = tr("%d of %d servers connected") % [states.values().filter(func(s): return s.state == "connected").size(), entries.size()]
		if is_instance_valid(touch_start): touch_start.available = states.values().any(func(s): return s.state == "connected")
	func _start_connected_workspace() -> void:
		starts += 1
	func _activate(key: String) -> void:
		activated_keys.append(key)
	func _remove_server(key: String) -> void:
		removed_keys.append(key)
		entries.erase(key)
		cards[key].queue_free()
		cards.erase(key)

var failures := 0
var screenshot_dir := ""

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("server-home-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot-dir="): screenshot_dir = arg.trim_prefix("--screenshot-dir=")
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func settle() -> void:
	for i in 8: await process_frame

func click(button: Button) -> void:
	var at := button.get_global_rect().get_center()
	if button.get_window() != root:
		at += Vector2(button.get_window().position)
	await click_at(at)

func click_at(at: Vector2) -> void:
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event)
		await process_frame
	await settle()

func screenshot(name: String) -> void:
	if screenshot_dir.is_empty() or DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(screenshot_dir)
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(screenshot_dir.path_join(name + ".png"))

func run() -> void:
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	var fixture_nodes := Node.get_orphan_node_ids()
	var home := Home.new()
	root.add_child(home)
	var keys: Array[String] = []
	for i in 8:
		var platform: String = ["macos", "windows", "linux", ""][i % 4]
		keys.append(home._remember_entry({"url": "ws://build-%d.example.test:7183" % i, "hostname": "Build-%d" % i, "username": "developer", "platform": platform, "name": ""}, "connected", "Connected"))
	var card: Control = home.cards[keys[0]]
	var localization := root.get_node("Localization")
	for language in ["fr", "de", "en-US"]:
		localization.set_language(language, false)
		for extent in [Vector2i(820, 910), Vector2i(360, 780), Vector2i(780, 360), Vector2i(360, 280)]:
			root.size = extent
			root.content_scale_size = extent
			await settle()
			var area := Rect2(Vector2.ZERO, Vector2(extent))
			var context := "%s %s: " % [language, extent]
			check(home.chooser.size.x <= extent.x + 1, context + "page fits viewport")
			check(area.encloses(home.connection_tab.get_global_rect()) and area.encloses(home.settings_tab.get_global_rect()), context + "sticky navigation stays on-screen")
			check(absf(home.brand.get_global_rect().get_center().x - extent.x * .5) < 1 and home.brand.size.y <= 60, context + "small logo is centered")
			if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
				var bubble: Rect2 = home.touch_start.bubble.get_global_rect()
				check(area.encloses(bubble) and bubble.size.x <= 180, context + "speech bubble stays compact and on-screen")
				var logo: Rect2 = home.brand.get_global_rect()
				check(home.touch_start.bubble_rect.size.y >= 48 and bubble.position.x > logo.end.x and absf(bubble.get_center().y - logo.get_center().y) < 1, context + "large start bubble is beside the logo on its right")
				check(home.touch_start.bubble.get_line_count() <= 3 and home.touch_start.bubble.size.y >= home.touch_start.bubble.get_minimum_size().y, context + "translated start prompt fits without clipping")
			check(not home.chooser.primary.visible and not home.chooser.heading.visible, context + "no redundant heading or return button")
			for item in home.cards.values():
				var bounds: Rect2 = item.get_global_rect()
				check(bounds.position.x >= 0 and bounds.end.x <= extent.x + 1, context + "device row stays inside viewport")
			check(card.status.get_global_rect().position.y >= card.heading.get_global_rect().end.y, context + "status is below hostname")
			check(card.address.get_global_rect().position.y >= card.status.get_global_rect().end.y and card.address.size.y >= 20, context + "address is visible below status")
			check(card.status.size.y <= 24, context + "Connected stays on a single line")
			for button in [home.connection_tab, home.settings_tab]:
				var font: Font = button.get_theme_font("font")
				var text_width: float = font.get_string_size(button.tr(button.text), HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x
				check(button.size.x >= text_width + button.icon.get_width() + button.get_theme_stylebox("normal").get_minimum_size().x + button.get_theme_constant("h_separation"), context + "navigation label never wraps")
		var nav_y := home.connection_tab.get_global_rect().position.y
		home.chooser.scroll.scroll_vertical = 500
		await settle()
		check(home.connection_tab.get_global_rect().position.y == nav_y, language + ": scrolling never moves navigation")
		home.chooser.scroll.scroll_vertical = 0
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		await click_at(home.brand.get_global_rect().get_center())
		await click_at(home.touch_start.bubble.get_global_rect().get_center())
		check(home.starts == 2, "Logo and speech bubble activate the same start action")
		home.touch_start.available = false
		await settle()
		await click_at(home.brand.get_global_rect().get_center())
		check(home.starts == 2 and not home.touch_start.bubble.visible and home.brand.is_visible_in_tree(), "No connected server disables starting and leaves the centered logo visible")
		home.touch_start.available = true
	root.size = Vector2i(820, 910)
	root.content_scale_size = root.size
	localization.set_language("fr", false)
	await settle()
	await screenshot("connections")
	await click(card.select)
	check(home.activated_keys == [keys[0]], "Tapping a device invokes its connection action")
	await click(card.more)
	check(card.actions.visible and home.activated_keys.size() == 1, "Three dots open the menu without activating the connection")
	check(card.action.is_visible_in_tree() and card.remove.is_visible_in_tree(), "Popup contains the existing actions")
	check(card.actions.size.y <= 240 and root.get_visible_rect().encloses(Rect2(card.actions.position, card.actions.size)), "Overflow is a compact anchored menu, not a full-height panel")
	check(absf(card.actions.position.x + card.actions.size.x - card.more.get_global_rect().end.x) <= 1 and absf(card.actions.position.y - card.more.get_global_rect().end.y) <= 1, "Overflow anchors to the three dots, not the viewport origin (popup %s %s, opener %s)" % [card.actions.position, card.actions.size, card.more.get_global_rect()])
	await screenshot("actions")
	await click(card.remove)
	check(is_instance_valid(home.removal) and home.removal.visible and not card.actions.visible, "Remove opens a panelal confirmation, not inline controls")
	check(home.entries.has(keys[0]) and home.removed_keys.is_empty(), "Opening confirmation changes nothing")
	if not is_instance_valid(home.removal):
		quit(1)
		return
	await screenshot("remove")
	await click(home.removal.get_cancel_button())
	check(home.entries.has(keys[0]) and home.removed_keys.is_empty(), "Cancel preserves the server and credentials")
	await click(home.settings_tab)
	check(home.settings_section.visible and not home.connections_section.visible, "Settings tab switches content, not connections")
	await create_timer(.3).timeout
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		check(home.settings_tab.get_theme_stylebox(state).bg_color != home.connection_tab.get_theme_stylebox(state).bg_color, "Selected tab remains distinct: " + state)
	home._show_build_info()
	await settle()
	check(home.about_dialog.get_script() == preload("res://scenes/AboutDialog.gd"), "Manager uses the shared About dialog")
	check(home.about_dialog.size.y <= 340 and not home.about_dialog.report.fit_content, "About is compact and scrollable")
	await screenshot("about")
	await click(home.about_dialog.get_ok_button())
	check(home.font_cache_clear.is_visible_in_tree() and home.entries.size() == 8, "Settings owns font cache and retains servers")
	await screenshot("settings")
	await click(home.connection_tab)
	check(home.connections_section.visible and not home.settings_section.visible, "Connection tab restores the list")
	check(home.connection_tab.button_pressed and not home.settings_tab.button_pressed, "Connection keeps selected state after switching back")
	root.size = Vector2i(360, 780)
	root.content_scale_size = root.size
	await settle()
	await screenshot("folded")
	home._set_state(keys[1], "error", "Connection error · %s", ["The server rejected the connection; check its current password."])
	await settle()
	var failed: Control = home.cards[keys[1]]
	check(failed.status.size.y > 24 and failed.get_global_rect().encloses(failed.address.get_global_rect()), "Long errors wrap below hostname without covering the address or escaping the card")
	check(failed.status.modulate == Color("f3a35b"), "Error text retains its warning color")
	await click(card.more)
	await click(card.remove)
	await settle()
	check(root.get_visible_rect().encloses(Rect2(home.removal.position, home.removal.size)), "Translated confirmation fits folded screen")
	home._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(home.entries.has(keys[0]) and home.removed_keys.is_empty(), "Android Back cancels deletion without touching the saved server")
	await click(card.more)
	await click(card.remove)
	await click(home.removal.get_ok_button())
	check(home.removed_keys == [keys[0]] and not home.entries.has(keys[0]), "Confirmation removes exactly the selected saved server")
	home.federation.free()
	home.queue_free()
	await settle()
	# The slim fixture skips manager startup, so its pre-created editor and
	# timers were never parented. Release those just like the unit runner does.
	for id in Node.get_orphan_node_ids():
		if id in fixture_nodes or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	quit(0 if failures == 0 else 1)
