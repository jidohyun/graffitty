extends "res://tests/unit/test_case.gd"
const Protocol := preload("res://scenes/NotificationProtocol.gd")

func test_notification_multipart_base64_and_unicode() -> void:
	for step in range(1, 17):
		var parser := Protocol.new()
		var text := "한글\nsecond line\t✓"
		var encoded := Marshalls.utf8_to_base64(text).trim_suffix("=").trim_suffix("=")
		parser.receive("i=test:d=0;Title")
		for offset in range(0, encoded.length(), step):
			expect(parser.receive("i=test:p=body:e=1:d=0;" + encoded.substr(offset, step)).is_empty(), "Chunks wait until done")
		var result: Dictionary = parser.receive("i=test;")
		expect(result.get("body") == text, "Arbitrary base64 boundaries preserve UTF-8 and newlines: %d" % step)
		expect(result.get("title") == "Title", "Title and body assemble independently")
	var parser := Protocol.new()
	parser.receive("d=0:p=body:e=1;" + Marshalls.utf8_to_base64("one"))
	var result: Dictionary = parser.receive("p=body:e=1;" + Marshalls.utf8_to_base64("two"))
	expect(result.title == "onetwo", "Independently padded chunks and body-only title fallback")

func test_notification_metadata_buttons_icons_and_actions() -> void:
	var parser := Protocol.new()
	parser.receive("i=a:d=0:a=-focus,report:c=1:u=2:o=invisible:w=1234:n=" + Marshalls.utf8_to_base64("info") + ";Done")
	parser.receive("i=a:d=0:p=buttons:e=1;" + Marshalls.utf8_to_base64("Open\u2028Dismiss"))
	var result: Dictionary = parser.receive("i=a;")
	expect(not result.focus and result.report and result.close_report, "Actions persist across chunks")
	expect(result.timeout == 1234 and result.urgency == 2 and result.occasion == "invisible", "Display metadata persists")
	expect(result.buttons == ["Open", "Dismiss"], "Buttons retain their one-based order")
	expect(result.icon_names == ["info"], "Icon names decoded")
	var icons := Protocol.new()
	icons.receive("g=cache:p=icon:e=1;" + Marshalls.raw_to_base64(PackedByteArray([137,80,78,71])))
	result = icons.receive("g=cache;Cached icon")
	expect(result.icon == PackedByteArray([137,80,78,71]), "Icon-only transfer caches for later notification")

func test_notification_queries_and_invalid_data() -> void:
	var parser := Protocol.new()
	for kind in ["?", "alive", "close"]:
		expect(parser.receive("i=query:p=" + kind + ";").op == kind, "Control operation " + kind)
	expect(parser.receive("i=bad id;unsafe").is_empty(), "Invalid identity rejected")
	expect(parser.receive("p=icon;unencoded").is_empty(), "Binary icons require base64")
	expect(parser.receive("e=1;!!!").is_empty(), "Invalid encoding rejected")
	expect(parser.receive("e=1;A").is_empty(), "Incomplete encoding rejected")
	expect(parser.receive(";" + "a".repeat(2049)).is_empty(), "Oversized chunks rejected")
	parser.receive("i=x:d=0;stale")
	parser.receive("i=x:p=close;")
	expect(parser.receive("i=x;fresh").title == "fresh", "Closing discards partial data")
	expect(Protocol.reply("bad;id", "close") == "\u001b]99;i=0:p=close;\u001b\\", "Replies cannot inject terminal commands")

func test_notification_universal_icons_precede_transmitted_data() -> void:
	var resolver := preload("res://scenes/NotificationIcons.gd")
	for name in ["error", "warn", "warning", "info", "question", "help", "file-manager", "system-monitor", "text-editor"]:
		var bytes: PackedByteArray = resolver.resolve(["missing-graffitty-icon-xyz", name], "", PackedByteArray([1]))
		expect(bytes.slice(0, 8) == PackedByteArray([137,80,78,71,13,10,26,10]), "Universal icon resolves before image fallback: " + name)
	expect(resolver.resolve(["missing-graffitty-icon-xyz"], "", PackedByteArray([1])) == PackedByteArray([1]), "Unknown names fall back to transmitted image")
