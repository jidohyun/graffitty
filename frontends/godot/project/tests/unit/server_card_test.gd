extends "res://tests/unit/test_case.gd"
const Card := preload("res://scenes/remote/ServerCard.gd")
const Name := preload("res://scenes/remote/ConnectionName.gd")

func test_display_address_keeps_ports_paths_and_ipv6_without_changing_endpoint() -> void:
	for pair in [["ws://example.test:7183", "example.test:7183"], ["wss://example.test:8443/ws?mode=1", "example.test:8443/ws?mode=1"], ["ws://[2001:db8::1]:7183/", "[2001:db8::1]:7183"], ["wss://[2001:db8::1]/ws", "[2001:db8::1]:443/ws"], ["wss://example.test/", "example.test:443"], ["ws://example.test/", "example.test:80"]]:
		var settings := {"url": pair[0]}
		expect(Name.address(settings) == pair[1], "Readable endpoint preserves address/port: " + pair[0])
		expect(settings.url == pair[0], "Presentation never changes the authentication endpoint")

func test_authenticated_identity_selects_os_and_optional_username() -> void:
	var card := Card.new()
	var settings := {"url": "ws://example.test:7183", "hostname": "BuildHost", "platform": "linux", "username": "developer", "name": ""}
	card.update_identity(settings)
	expect(card.heading.text == "developer@BuildHost", "Known server account appears with hostname")
	expect(card.os_icon.texture == Card._icon("os-linux"), "OS comes from authenticated metadata")
	settings.name = "Office"
	card.update_identity(settings)
	expect(card.heading.text == "Office" and card.select.accessibility_name.contains("Office"), "Alias remains explicit and accessible")
	settings.platform = ""
	settings.username = ""
	settings.name = ""
	card.update_identity(settings)
	expect(card.heading.text == "BuildHost" and card.os_icon.texture == Card._icon("monitor"), "Unknown metadata is never guessed")
	card.free()

func test_connection_card_contains_only_server_details_without_duplicate_tooltips() -> void:
	var card := Card.new()
	card.update_identity({"url": "ws://example.test:7183", "name": "Office"})
	card.status.text = "Connected"
	card.update_state("connected", true)
	var labels := card.select.find_children("*", "Label", true, false).map(func(label): return label.text)
	expect(labels == ["Office", "Connected", "example.test:7183"], "Connection card shows only server identity, status and address")
	expect([card.select, card.heading, card.address, card.os_icon].all(func(control): return control.get_tooltip().is_empty()), "Card identity has no duplicate tooltip when held to reorder")
	expect(card.select.accessibility_name == "Office\nexample.test:7183\nConnected", "Server details remain available to assistive technology")
	card.free()

func test_actions_are_only_in_menu_and_remove_is_red_with_svg() -> void:
	var card := Card.new()
	expect(not card.actions.visible, "Overflow starts hidden")
	for button in [card.action, card.edit, card.disconnect_button, card.remove]:
		expect(card.actions.is_ancestor_of(button) and button.custom_minimum_size.y >= 48, "All four actions are touch-sized menu items")
	expect(card.remove.icon != null and card.remove.get_theme_color("font_color") == Card.DANGER, "Remove has an SVG and red text")
	expect(card.remove.get_theme_color("icon_normal_color") == Card.DANGER, "Remove icon is red too")
	card.status.text = "Connected"
	card.update_state("connected", true)
	expect(card.action.text == "Connected" and not card.select.disabled, "Card reports its server connection state")
	card.update_state("offline", true)
	expect(card.action.text == "Retry now" and not card.action.disabled, "Offline menu offers retry")
	card.update_state("disconnected", false)
	expect(card.disconnect_button.disabled and card.action.text == "Connect", "A saved offline server cannot be disconnected twice")
	card.update_state("connecting", true)
	expect(card.action.disabled and card.select.disabled, "Neither card nor menu duplicates an in-flight connection")
	expect(card.status.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "Full errors can wrap below hostname")
	card.free()
