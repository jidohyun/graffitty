extends ConfirmationDialog
var host: Node
var draft: Dictionary
var fields: Dictionary = {}
var captions: Dictionary = {}
var basic := GridContainer.new()
var advanced := CheckButton.new()
var editor := TextEdit.new()
var status := Label.new()
var ligatures := CheckBox.new()
var busy := false

func _ready() -> void:
	title = "Fonts"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	draft = host.session_backend.connection.fonts_for(host.active_session_id).config.duplicate(true)
	var column := VBoxContainer.new()
	add_child(column)
	var scope := Label.new()
	scope.text = "Applies to all terminal panes on this local owner, including future panes."
	column.add_child(scope)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	advanced.text = "Advanced fonts (complete JSON)"
	column.add_child(advanced)
	basic.columns = 2
	column.add_child(basic)
	for spec in [["family","Installed family (empty = bundled)"],["size","Font size"],["regular","Regular font file"],["bold","Bold font file"],["italic","Italic font file"],["bold_italic","Bold italic font file"],["fallbacks","Fallback families (comma separated)"],["line_height","Line height (%)"],["column_width","Column width (%)"],["cell_width","Cell width (0 = automatic)"],["cell_height","Cell height (0 = automatic)"]]:
		var label := Label.new()
		label.text = spec[1]
		basic.add_child(label)
		var edit := LineEdit.new()
		edit.custom_minimum_size.x = 340
		basic.add_child(edit)
		fields[spec[0]] = edit
		captions[spec[0]] = spec[1]
	ligatures.text = "Ligatures"
	basic.add_child(ligatures)
	editor.custom_minimum_size = Vector2(650,380).min(host.get_viewport().get_visible_rect().size * .7)
	editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	column.add_child(editor)
	editor.hide()
	_fill()
	advanced.toggled.connect(_advanced)
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func _fill() -> void:
	for name in ["family","size","cell_width","cell_height"]: fields[name].text = str(draft[name])
	for name in ["line_height","column_width"]: fields[name].text = String.num(float(draft[name])*100,3)
	fields.fallbacks.text = ", ".join(draft.fallbacks)
	for i in 4: fields[["regular","bold","italic","bold_italic"][i]].text = str(draft.paths[i]) if i < draft.paths.size() else ""
	ligatures.button_pressed = bool(draft.ligatures)

func _read_basic() -> bool:
	var next := draft.duplicate(true)
	for name in ["size","cell_width","cell_height","line_height","column_width"]:
		var text: String = fields[name].text
		if not text.is_valid_float() or not is_finite(float(text)):
			status.text = tr("Enter a finite number for %s.") % tr(captions[name])
			return false
		if name in ["size","cell_width","cell_height"]:
			if float(text) != floorf(float(text)):
				status.text = tr("Enter a whole number for %s.") % tr(captions[name])
				return false
			next[name] = int(text)
		else: next[name] = float(text)/100
	next.family = fields.family.text.strip_edges()
	next.paths = []
	for name in ["regular","bold","italic","bold_italic"]: next.paths.append(fields[name].text.strip_edges())
	while not next.paths.is_empty() and next.paths.back().is_empty(): next.paths.pop_back()
	next.fallbacks = []
	for name in fields.fallbacks.text.split(",",false): next.fallbacks.append(name.strip_edges())
	next.ligatures = ligatures.button_pressed
	draft = next
	return true

func _read_json() -> bool:
	var json := JSON.new()
	if json.parse(editor.text) != OK or not json.data is Dictionary:
		status.text = tr("Enter a JSON object. %s") % json.get_error_message()
		return false
	# The editor represents the complete current document, including advanced fields.
	if json.data.keys().size() != draft.keys().size():
		status.text = "Keep every field in the complete font settings document."
		return false
	for key in draft:
		if not json.data.has(key):
			status.text = tr("Missing font field: %s") % key
			return false
	if not json.data.family is String or not json.data.paths is Array or not json.data.fallbacks is Array or not json.data.ligatures is bool:
		status.text = "Family must be text, paths and fallbacks arrays of text, and ligatures a boolean."
		return false
	for value in json.data.paths + json.data.fallbacks:
		if not value is String:
			status.text = "Font paths and fallback names must be text."
			return false
	for key in ["size","cell_width","cell_height","line_height","column_width"]:
		if not (json.data[key] is float or json.data[key] is int):
			status.text = tr("Font %s must be numeric.") % key
			return false
	for key in ["size","cell_width","cell_height"]:
		if float(json.data[key]) != floorf(float(json.data[key])):
			status.text = tr("Font %s must be a whole number.") % key
			return false
		json.data[key] = int(json.data[key])
	if not json.data.features is Dictionary or not json.data.variations is Dictionary or not json.data.symbol_maps is Array:
		status.text = "Features and variations must be objects, and symbol maps an array."
		return false
	for key in json.data.features:
		var value: Variant = json.data.features[key]
		if not (value is float or value is int) or float(value) != floorf(float(value)):
			status.text = "Feature values must be whole numbers."
			return false
		json.data.features[key] = int(value)
	for mapping in json.data.symbol_maps:
		if not mapping is Dictionary:
			status.text = "Each symbol map must be an object."
			return false
		for key in ["first","last"]:
			var value: Variant = mapping.get(key)
			if not (value is float or value is int) or float(value) != floorf(float(value)):
				status.text = "Symbol range bounds must be whole numbers."
				return false
			mapping[key] = int(value)
	draft = json.data
	return true

func _advanced(enabled: bool) -> void:
	if enabled:
		if not _read_basic():
			advanced.set_pressed_no_signal(false)
			return
		editor.text = JSON.stringify(draft,"  ")
	else:
		if not _read_json():
			advanced.set_pressed_no_signal(true)
			return
		_fill()
	basic.visible = not enabled
	editor.visible = enabled
	reset_size()
	popup_centered()

func apply_changes() -> void:
	if busy: return
	if not (_read_json() if advanced.button_pressed else _read_basic()): return
	busy = true
	get_ok_button().disabled = true
	var reply: Dictionary = await host.session_backend.connection.request_action("font_config",{"config":draft})
	busy = false
	get_ok_button().disabled = false
	if reply.get("type") == "error":
		status.text = str(reply.get("message","Font settings rejected"))
		preload("res://graffitty/diagnostics.gd").user_message(tr("Font settings: %s") % tr(status.text))
		return
	queue_free()
