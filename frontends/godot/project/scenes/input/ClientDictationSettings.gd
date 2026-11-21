extends AcceptDialog
const Provider := preload("res://scenes/input/ClientDictation.gd")
var provider := OptionButton.new()
var key: LineEdit = preload("res://scenes/SecretInput.gd").new()
var message := Label.new()

func _ready() -> void:
	title = tr("Client-side dictation")
	min_size = Vector2i(540, 320)
	var column := VBoxContainer.new()
	add_child(column)
	var help := Label.new()
	help.text = tr("After Stop, audio goes directly to the selected provider (maximum 60 seconds). Leave the key blank to reuse its saved key.")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)
	provider.add_item(tr("Gemini"))
	provider.add_item(tr("OpenAI"))
	var selected := Provider.PROVIDERS.find(Provider.selected_provider())
	provider.select(maxi(0, selected))
	provider.item_selected.connect(func(_index: int):
		key.clear()
		message.text = "")
	column.add_child(provider)
	key.placeholder_text = tr("API key")
	column.add_child(key)
	column.add_child(message)
	get_ok_button().text = tr("Save")
	add_cancel_button(tr("Cancel"))
	add_button(tr("Use server"), true, "server")
	dialog_hide_on_ok = false
	confirmed.connect(func():
		_save(Provider.PROVIDERS[provider.selected], key.text.strip_edges()))
	custom_action.connect(func(action: StringName):
		if action == &"server": _save("server", ""))
	visibility_changed.connect(func():
		if not visible: key.clear())

func _save(selected: String, value: String) -> void:
	if Provider.save_selection(selected, value):
		key.clear()
		hide()
	else:
		message.text = tr("Cannot save client dictation key")
