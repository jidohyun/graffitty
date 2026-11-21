extends "res://tests/unit/test_case.gd"
const Name := preload("res://scenes/remote/ConnectionName.gd")
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")

func test_optional_name_prefers_server_hostname_and_preserves_case() -> void:
	var settings := {"url": "ws://192.0.2.1:8080", "name": "", "hostname": "MyMac"}
	expect(Name.display(settings) == "MyMac", "Blank name uses actual server hostname, even for an IP address")
	settings.name = "  Work Mac  "
	expect(Name.display(settings) == "Work Mac", "Explicit alias takes precedence and preserves case")
	settings.name = "   "
	expect(Name.display(settings) == "MyMac", "Clearing the alias restores the hostname")

func test_address_fallback_for_older_servers() -> void:
	for pair in [["wss://MyMac.local:443/ws", "MyMac.local"], ["ws://192.0.2.1:8080", "192.0.2.1"], ["ws://[2001:db8::1]:8080", "2001:db8::1"], ["wss://user:password@MyMac.local/path", "MyMac.local"]]:
		expect(Name.display({"url": pair[0]}) == pair[1], "Address fallback strips URL details")

func test_saved_hostname_does_not_become_an_explicit_alias() -> void:
	var settings := {"url": "ws://192.0.2.77:8080", "hostname": "MyMac", "platform": "macos", "username": "developer"}
	expect(Authentication.save_connection(settings).is_empty(), "Unnamed connection saves successfully")
	var saved: Array = Authentication.saved_connections().filter(func(item): return item.url == settings.url)
	expect(saved.size() == 1 and saved[0].name == "" and saved[0].hostname == "MyMac", "Saved connection keeps automatic hostname separate from optional alias")
	expect(saved[0].platform == "macos" and saved[0].username == "developer", "Authenticated OS/account persist without needing to reconnect for display")
