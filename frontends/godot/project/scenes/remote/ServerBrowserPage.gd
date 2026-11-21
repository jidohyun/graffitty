extends "res://scenes/remote/ConnectionPage.gd"
## Shared responsive server-list presentation. Platform controllers own connections.
signal add_requested
var brand := TextureRect.new()
var connections := VBoxContainer.new()
var status := Label.new()
var status_row := HBoxContainer.new()
var empty := Label.new()
var rows := VBoxContainer.new()
var add_server := Button.new()

func _init() -> void:
	scroll_through_controls = true
	max_content_width = 1000.0

func _ready() -> void:
	super()
	heading.hide()
	primary.hide()
	back.hide()
	brand.texture = preload("res://scenes/icons/graffitty-logo.webp")
	brand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	brand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	brand.custom_minimum_size = Vector2(144, 58)
	brand.accessibility_name = "Graffitty"
	header.custom_minimum_size.y = 76
	header.add_child(brand)
	header.show()
	connections.add_theme_constant_override("separation", 14)
	body.add_child(connections)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Connect to a computer running Graffitty."
	connections.add_child(status_row)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(status)
	empty.text = "No saved servers yet."
	empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connections.add_child(empty)
	rows.add_theme_constant_override("separation", 10)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connections.add_child(rows)
	add_server.text = "+ " + tr("Add server")
	add_server.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	add_server.accessibility_name = tr("Add server")
	add_server.custom_minimum_size.y = 48
	style_button(add_server)
	add_server.pressed.connect(func(): add_requested.emit())
	connections.add_child(add_server)
	get_node("/root/Localization").changed.connect(func():
		add_server.text = "+ " + tr("Add server")
		add_server.accessibility_name = tr("Add server"))
