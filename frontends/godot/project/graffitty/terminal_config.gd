extends RefCounted
## User preferences supplied to worlds. Worlds may copy, override, or replace them.
## Shell creation and resource budgets belong to server.toml. Keyboard shortcuts
## for terminal actions belong to the shared client bindings, not this object.


class Background extends RefCounted:
	var color: Color = Color("#282c34")
	var alpha: float = 0.85


class CursorTrail extends RefCounted:
	var style: String = "lightning"
	var smear: Dictionary = {"color": Color.TRANSPARENT} # Transparent follows the cursor color.
	var blaze: Dictionary = {"duration": 0.5, "color": Color("#ffb929"), "accent_color": Color("#ff0000")}
	var lightning: Dictionary = {"duration": 0.14, "color": Color("#ffb929"), "glow_color": Color("#bd0000"), "jaggedness": 0.085, "core_width": 1.15, "glow_width": 5.5}
	var delay_ms: int = 3 # Zero disables the trail.
	var decay: Vector2 = Vector2(0.1, 0.4) # Fast/slow corners, seconds.
	var start_threshold: Vector2 = Vector2(2, 2) # Horizontal/vertical cells.


class TypingParticles extends RefCounted:
	var preset: String = "sparks" # none, sparks, basic, fireworks, flames, glitter.
	var amount: int = 6
	var scale: float = 1.0


class TypingPaneZoom extends RefCounted:
	var scale: float = 1.1 # 1.0 disables pane enlargement; independent of camera zoom.


class TerminalEffects extends RefCounted:
	var cursor_trail := CursorTrail.new()
	var typing_particles := TypingParticles.new()
	var typing_pane_zoom := TypingPaneZoom.new()


class KeyBinding extends RefCounted:
	var key: InputEventKey
	var action: String


	func _init(event: Variant, command: String) -> void:
		if event is InputEventKey:
			key = event
		elif event is int:
			key = InputEventKey.new()
			key.keycode = event & KEY_CODE_MASK
			key.ctrl_pressed = bool(event & KEY_MASK_CTRL)
			key.shift_pressed = bool(event & KEY_MASK_SHIFT)
			key.alt_pressed = bool(event & KEY_MASK_ALT)
			key.meta_pressed = bool(event & KEY_MASK_META)
		# Unsupported values remain null and are reported by validate().
		action = command


const LEADER := -1


class SymbolMap extends RefCounted:
	var first: int
	var last: int
	var family: String


	func _init(start: int = 0, end: int = 0, font_family: String = "") -> void:
		first = start
		last = end
		family = font_family


class MouseBinding extends RefCounted:
	var button: MouseButton
	var modifiers: int
	var action: String


	func _init(
		mouse_button: MouseButton = MOUSE_BUTTON_LEFT,
		command: String = "select",
		mask: int = 0,
	) -> void:
		button = mouse_button
		modifiers = mask
		action = command


class KeySequence extends RefCounted:
	var keys: Array
	var action: String


	func _init(events: Array = [], command: String = "ignore") -> void:
		keys = events
		action = command


class KeyTable extends RefCounted:
	var bindings: Array[KeyBinding] = []
	var sequences: Array[KeySequence] = []
	var one_shot: bool = true
	var timeout_ms: int = 1000


const ACTIONS := [
	"search",
	"quick_select",
	"copy_mode",
	"copy_last_output",
	"copy",
	"paste",
	"previous_prompt",
	"next_prompt",
	"scroll_page_up",
	"scroll_page_down",
	"scroll_top",
	"scroll_bottom",
	"increase_font_size",
	"decrease_font_size",
	"reset_font_size",
	"ignore",
	"pop_key_table",
]
var font_family: String = ""
var font_fallbacks: PackedStringArray = [] # Installed families, in priority order; missing glyphs only.
# Explicit files override font_family. Regular is required when using files.
# Empty style paths reuse the regular face; these are not fallback fonts.
var font_regular_path: String = ""
var font_bold_path: String = ""
var font_italic_path: String = ""
var font_bold_italic_path: String = ""
var font_size: int = 16 # Reference-layout pixels, before world scaling.
var ligatures: bool = true
var line_height: float = 1.0
var column_width: float = 1.0
var foreground: Color = Color.WHITE
var palette: PackedColorArray = PackedColorArray(
	[
		Color("#1d1f21"),
		Color("#cc6666"),
		Color("#b5bd68"),
		Color("#f0c674"),
		Color("#81a2be"),
		Color("#b294bb"),
		Color("#8abeb7"),
		Color("#c5c8c6"),
		Color("#666666"),
		Color("#d54e53"),
		Color("#b9ca4a"),
		Color("#e7c547"),
		Color("#7aa6da"),
		Color("#c397d8"),
		Color("#70c0b1"),
		Color("#eaeaea"),
	]
)
var palette_overrides: Dictionary[int, Color] = { } # Optional indices 0..255.
var selection_foreground: Color = Color.TRANSPARENT # Preserve text color; both transparent invert.
var selection_background: Color = Color("#7f6699")
var cursor_color: Color = Color.WHITE
var cursor_shape: String = "auto" # auto, block, beam, underline, hollow.
var text_outline: bool = false
var text_outline_width: float = 1.0
var text_outline_color: Color = Color("#000000bf")
var background := Background.new()
var effects := TerminalEffects.new()
var clipboard_read: String = "ask" # OSC 52: deny, ask, allow.
var clipboard_write: bool = true # OSC 52 writes; does not disable explicit Copy.
var open_hyperlinks: bool = true

var font_features: Dictionary[String, int] = { }
var font_variations: Dictionary[String, float] = { }
var symbol_maps: Array[SymbolMap] = []
var cursor_blink: String = "auto"
var cursor_blink_interval_ms: int = 500
var cursor_beam_thickness: float = 0.0
var cursor_underline_thickness: float = 0.0
var mouse_bindings: Array[MouseBinding] = default_mouse_bindings()
var scroll_multiplier: float = 1.0
var mouse_bypass_modifiers: int = KEY_MASK_SHIFT
var selection_word_boundaries: Variant = null
var iskeyword: Array[String] = ["@", "48-57", "_", "192-255"] # Neovim rules; append("-") to include hyphens.
var copy_on_select: String = "primary"
var quick_select_patterns: PackedStringArray = []
var quick_select_defaults: bool = true
var quick_select_alphabet: String = "asdfqwerzxcvjklmiuopghtybn"
var modal_key_bindings: Dictionary[String, Array] = default_modal_bindings()
var leader: Variant = null
var sequence_timeout_ms: int = 1000
var key_sequences: Array[KeySequence] = []
var key_tables: Dictionary[String, KeyTable] = { }
var hyperlink_patterns: PackedStringArray = [r"(?:https?://|ftp://|file://)[^\s<>\"]+"]
var hyperlink_handler: Callable
var audible_bell: bool = false
var visual_bell_duration_ms: int = 0
var visual_bell_color: Color = Color(1, 1, 1, 0.25)


static func default_mouse_bindings() -> Array[MouseBinding]:
	return [
		MouseBinding.new(MOUSE_BUTTON_LEFT, "select"),
		MouseBinding.new(MOUSE_BUTTON_LEFT, "select", KEY_MASK_ALT),
		MouseBinding.new(MOUSE_BUTTON_LEFT, "open_link", KEY_MASK_CTRL),
		MouseBinding.new(MOUSE_BUTTON_LEFT, "open_link", KEY_MASK_META),
		MouseBinding.new(MOUSE_BUTTON_MIDDLE, "paste_primary"),
		MouseBinding.new(MOUSE_BUTTON_WHEEL_UP, "scroll_up"),
		MouseBinding.new(MOUSE_BUTTON_WHEEL_DOWN, "scroll_down"),
	]


static func default_modal_bindings() -> Dictionary[String, Array]:
	var maps := {
		# Copy mode and its search prompt take Vim keys natively; an entry here
		# overrides one key with a named action.
		"search": { },
		"quick_select": {
			KEY_ESCAPE: "cancel",
			KEY_BACKSPACE: "backspace",
			KEY_U | KEY_MASK_CTRL: "clear",
			KEY_UP: "previous",
			KEY_DOWN: "next",
			KEY_ENTER: "previous",
			KEY_PAGEUP: "page_up",
			KEY_PAGEDOWN: "page_down",
			KEY_P | KEY_MASK_CTRL: "previous",
			KEY_N | KEY_MASK_CTRL: "next",
		},
		"copy_mode": { },
	}
	var copy_key := KEY_C | (
		KEY_MASK_META if OS.get_name() == "macOS" else KEY_MASK_CTRL | KEY_MASK_SHIFT
	)
	maps.search[copy_key] = "copy"
	maps.copy_mode[copy_key] = "accept"
	var result: Dictionary[String, Array] = { }
	for mode in maps:
		result[mode] = []
		for key in maps[mode]:
			result[mode].append(KeyBinding.new(key, maps[mode][key]))
	return result


static func _event_code(event: Variant) -> int:
	if event is int and event == LEADER:
		return LEADER
	var binding := KeyBinding.new(event, "ignore")
	return binding.key.get_keycode_with_modifiers() if binding.key != null else 0


static func _sequence(sequence: KeySequence) -> Dictionary:
	var keys := PackedInt64Array()
	for event in sequence.keys:
		keys.append(_event_code(event))
	return { "keys": keys, "action": sequence.action }


func compiled_advanced() -> Dictionary:
	var result := { }
	result.text_outline_width = text_outline_width if text_outline else 0.0
	result.text_outline_color = text_outline_color
	for property in ADVANCED_FIELDS:
		result[property] = get(property)
	result.iskeyword = ",".join(iskeyword)
	result.cursor_blink = { "auto": -1, "off": 0, "on": 1 }[cursor_blink]
	result.font_features = { }
	result.font_features.merge(font_features)
	result.font_variations = { }
	result.font_variations.merge(font_variations)
	var symbols: Array[Dictionary] = []
	for item in symbol_maps:
		symbols.append({ "first": item.first, "last": item.last, "family": item.family })
	result.symbol_maps = symbols
	var mouse: Array[Dictionary] = []
	for binding in mouse_bindings:
		mouse.append(
			{ "button": binding.button, "modifiers": binding.modifiers, "action": binding.action }
		)
	result.mouse_bindings = mouse
	result.modal_bindings = { }
	for mode in modal_key_bindings:
		result.modal_bindings[mode] = { }
		for binding in modal_key_bindings[mode]:
			result.modal_bindings[mode][binding.key.get_keycode_with_modifiers()] = binding.action
	result.leader = _event_code(leader)
	# The native adapter reads Array[Dictionary]. An untyped Array silently
	# fails that conversion and drops the user's sequences/table bindings.
	var sequences: Array[Dictionary] = []
	for sequence in key_sequences:
		sequences.append(_sequence(sequence))
	result.key_sequences = sequences
	result.key_tables = { }
	for name in key_tables:
		var table := key_tables[name]
		var entries: Array[Dictionary] = []
		for binding in table.bindings:
			entries.append(
				{
					"keys": PackedInt64Array([binding.key.get_keycode_with_modifiers()]),
					"action": binding.action,
				}
			)
		for sequence in table.sequences:
			entries.append(_sequence(sequence))
		result.key_tables[name] = {
			"bindings": entries,
			"one_shot": table.one_shot,
			"timeout_ms": table.timeout_ms,
		}
	if selection_word_boundaries != null:
		result.word_boundaries = selection_word_boundaries
	return result


static func _copy_value(value: Variant) -> Variant:
	if value is InputEventKey:
		return value.duplicate()
	if value is KeyBinding:
		return KeyBinding.new(_copy_value(value.key), value.action)
	if value is KeySequence:
		return KeySequence.new(_copy_value(value.keys), value.action)
	if value is SymbolMap:
		return SymbolMap.new(value.first, value.last, value.family)
	if value is MouseBinding:
		return MouseBinding.new(value.button, value.action, value.modifiers)
	if value is KeyTable:
		var table := KeyTable.new()
		table.bindings = _copy_value(value.bindings)
		table.sequences = _copy_value(value.sequences)
		table.one_shot = value.one_shot
		table.timeout_ms = value.timeout_ms
		return table
	if value is Array or value is Dictionary:
		var result = value.duplicate()
		for key in value.keys() if value is Dictionary else range(value.size()):
			result[key] = _copy_value(value[key])
		return result
	if value is PackedStringArray:
		return value.duplicate()
	return value


func copy():
	var result = get_script().new()
	for property in get_property_list():
		if not property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			continue
		var value = get(property.name)
		if value is Dictionary or value is Array:
			value = value.duplicate(true)
		result.set(property.name, value)
	for property in ADVANCED_FIELDS:
		result.set(property, _copy_value(get(property)))
	result.font_fallbacks = font_fallbacks.duplicate()
	result.palette = palette.duplicate()
	result.effects = TerminalEffects.new()
	var groups := {
		"background": Background.new(),
		"cursor_trail": CursorTrail.new(),
		"typing_particles": TypingParticles.new(),
		"typing_pane_zoom": TypingPaneZoom.new(),
	}
	for group in groups:
		var original = background if group == "background" else effects.get(group)
		var replacement = groups[group]
		for property in original.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				replacement.set(property.name, _copy_value(original.get(property.name)))
		if group == "background": result.background = replacement
		else: result.effects.set(group, replacement)
	return result


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if effects.cursor_trail.style not in ["smear", "blaze", "lightning"]:
		errors.append("effects.cursor_trail.style must be smear, blaze, or lightning")
	for style_name in ["smear", "blaze", "lightning"]:
		var options: Dictionary = effects.cursor_trail.get(style_name)
		for key in options:
			var value = options[key]
			if key.ends_with("color"):
				if not value is Color: errors.append("effects.cursor_trail.%s.%s must be a Color" % [style_name, key])
			elif not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0 or (key != "jaggedness" and float(value) == 0):
				errors.append("effects.cursor_trail.%s.%s must be a finite positive number" % [style_name, key])

	for rule in [
		["font_size", font_size, 1, 72],
		["line_height", line_height, 0.5, 3.0],
		["column_width", column_width, 0.5, 3.0],
		["background.alpha", background.alpha, 0, 1],
		["effects.cursor_trail.delay_ms", effects.cursor_trail.delay_ms, 0, 10000],
		["effects.cursor_trail.decay.x", effects.cursor_trail.decay.x, 0.001, 60],
		["effects.cursor_trail.decay.y", effects.cursor_trail.decay.y, effects.cursor_trail.decay.x, 60],
		["effects.cursor_trail.start_threshold.x", effects.cursor_trail.start_threshold.x, 0, 10000],
		["effects.cursor_trail.start_threshold.y", effects.cursor_trail.start_threshold.y, 0, 10000],
		["effects.typing_particles.amount", effects.typing_particles.amount, 1, 2048],
		["effects.typing_particles.scale", effects.typing_particles.scale, 0.01, 100],
		["effects.typing_pane_zoom.scale", effects.typing_pane_zoom.scale, 1.0, 2.0],
		["text_outline_width", text_outline_width, 0, 32],
	]:
		if not is_finite(float(rule[1])) or rule[1] < rule[2] or rule[1] > rule[3]:
			errors.append("%s must be between %s and %s" % [rule[0], rule[2], rule[3]])
	if effects.typing_particles.preset not in ["none", "sparks", "dots", "fireworks", "flames", "glitter"]:
		errors.append("Invalid effects.typing_particles.preset")
	if cursor_shape not in ["auto", "block", "bar", "beam", "underline", "hollow"]:
		errors.append("Invalid cursor_shape")
	if clipboard_read not in ["deny", "ask", "allow"]:
		errors.append("Invalid clipboard_read")
	if (
		font_regular_path.is_empty()
		and not (font_bold_path + font_italic_path + font_bold_italic_path).is_empty()
	):
		errors.append("font_regular_path is required when using explicit style files")
	for family in font_fallbacks:
		if family.strip_edges().is_empty():
			errors.append("font_fallbacks entries must be nonempty installed family names")
	if palette.size() != 16:
		errors.append("palette must contain 16 ANSI colors")
	for index in palette_overrides:
		if index < 0 or index > 255:
			errors.append("palette_overrides indices must be 0..255")
	errors.append_array(_validate_advanced())
	return errors


const ADVANCED_FIELDS := [
	"font_features",
	"font_variations",
	"symbol_maps",
	"cursor_blink",
	"cursor_blink_interval_ms",
	"cursor_beam_thickness",
	"cursor_underline_thickness",
	"mouse_bindings",
	"scroll_multiplier",
	"mouse_bypass_modifiers",
	"selection_word_boundaries",
	"iskeyword",
	"copy_on_select",
	"quick_select_patterns",
	"quick_select_defaults",
	"quick_select_alphabet",
	"modal_key_bindings",
	"leader",
	"sequence_timeout_ms",
	"key_sequences",
	"key_tables",
	"hyperlink_patterns",
	"hyperlink_handler",
	"audible_bell",
	"visual_bell_duration_ms",
	"visual_bell_color",
]


func _valid_action(action: String) -> bool:
	return (
		action in ACTIONS or action.begins_with("send_text:")
		or (
			action.begins_with("activate_key_table:")
			and key_tables.has(action.trim_prefix("activate_key_table:"))
		)
	)


func _validate_advanced() -> PackedStringArray:
	var errors := PackedStringArray()
	var keyword_error: String = ClassDB.class_call_static("Terminal", "validate_iskeyword", ",".join(iskeyword))
	if not keyword_error.is_empty():
		errors.append(keyword_error)
	if cursor_blink not in ["auto", "on", "off"]:
		errors.append("cursor_blink must be auto, on, or off")
	if copy_on_select not in ["none", "primary", "clipboard", "both"]:
		errors.append("Invalid copy_on_select")
	if selection_word_boundaries != null and not selection_word_boundaries is String:
		errors.append("selection_word_boundaries must be null or a string")
	for property in ["font_features", "font_variations"]:
		for tag in get(property):
			if tag.length() != 4 or not tag.is_valid_ascii_identifier():
				errors.append(property + " keys must be four-character OpenType tags")
	for rule in [
		["cursor_blink_interval_ms", cursor_blink_interval_ms, 1, 60000],
		["cursor_beam_thickness", cursor_beam_thickness, 0, 100],
		["cursor_underline_thickness", cursor_underline_thickness, 0, 100],
		["scroll_multiplier", scroll_multiplier, 0, 100],
		["sequence_timeout_ms", sequence_timeout_ms, 1, 60000],
		["visual_bell_duration_ms", visual_bell_duration_ms, 0, 60000],
	]:
		if not is_finite(float(rule[1])) or rule[1] < rule[2] or rule[1] > rule[3]:
			errors.append("%s must be between %s and %s" % [rule[0], rule[2], rule[3]])
	for axis in font_variations:
		if not is_finite(font_variations[axis]):
			errors.append("Font variation must be finite: " + axis)
	var letters := { }
	for letter in quick_select_alphabet:
		if letter < "a" or letter > "z" or letters.has(letter):
			errors.append("quick_select_alphabet requires unique lowercase ASCII letters")
		letters[letter] = true
	if letters.size() < 2:
		errors.append("quick_select_alphabet requires at least two letters")
	for pattern in Array(quick_select_patterns) + Array(hyperlink_patterns):
		var error: String = ClassDB.class_call_static("Terminal", "validate_pattern", pattern)
		if not error.is_empty():
			errors.append(error)
	for item in symbol_maps:
		if (
			item.first < 0 or item.last < item.first or item.last > 0x10ffff
			or item.family.strip_edges().is_empty()
		):
			errors.append("Invalid symbol map range or family")
	var mouse_seen := { }
	for binding in mouse_bindings:
		var id := str(binding.button) + ":" + str(binding.modifiers)
		if mouse_seen.has(id):
			errors.append("Duplicate mouse binding")
		mouse_seen[id] = true
		if binding.button < MOUSE_BUTTON_LEFT or binding.button > MOUSE_BUTTON_XBUTTON2:
			errors.append("Invalid mouse button")
		if (
			binding.action
			not in ["select", "open_link", "paste_primary", "scroll_up", "scroll_down"]
			and not _valid_action(binding.action)
		):
			errors.append("Invalid mouse action: " + binding.action)
	var mode_actions := [
		"cancel",
		"next",
		"previous",
		"left",
		"right",
		"up",
		"down",
		"page_up",
		"page_down",
		"line_start",
		"line_end",
		"top",
		"bottom",
		"toggle_selection",
		"accept",
		"copy",
		"refresh",
		"backspace",
		"clear",
		"ignore",
	]
	for mode in modal_key_bindings:
		if mode not in ["search", "copy_mode", "quick_select"]:
			errors.append("Unknown modal key table: " + mode)
		var seen := { }
		for binding in modal_key_bindings[mode]:
			if not binding is KeyBinding or binding.key == null:
				errors.append("Modal bindings require KeyBinding values")
				continue
			var code: int = binding.key.get_keycode_with_modifiers()
			if binding.action not in mode_actions or code == 0 or seen.has(code):
				errors.append("Invalid or duplicate modal binding in " + mode)
			seen[code] = true
	if leader != null and _event_code(leader) <= 0:
		errors.append("Invalid leader key")
	var sequences: Array = key_sequences.duplicate()
	for name in key_tables:
		var table := key_tables[name]
		if name.is_empty() or table.timeout_ms < 1 or table.timeout_ms > 60000:
			errors.append("Invalid key table name or timeout")
		var seen := { }
		for binding in table.bindings:
			if binding.key == null or not _valid_action(binding.action):
				errors.append("Invalid key table binding")
			elif seen.has(binding.key.get_keycode_with_modifiers()):
				errors.append("Duplicate key in table " + name)
			else:
				seen[binding.key.get_keycode_with_modifiers()] = true
		sequences.append_array(table.sequences)
	for sequence in sequences:
		if sequence.keys.is_empty() or not _valid_action(sequence.action):
			errors.append("Invalid key sequence")
		for i in sequence.keys.size():
			var code := _event_code(sequence.keys[i])
			if code == 0 or (code == LEADER and (i != 0 or leader == null)):
				errors.append("Invalid sequence key or unconfigured leader")
	return errors


# Bridge for existing terminal renderers and plain .conf presets.
const FIELDS := {
	"font_fallbacks": "font_fallbacks",
	"font_family": "font_family",
	"font_regular_path": "font_regular_path",
	"font_bold_path": "font_bold_path",
	"font_italic_path": "font_italic_path",
	"font_bold_italic_path": "font_bold_italic_path",
	"font_size": "font_size",
	"ligatures": "ligatures",
	"line_height": "line_height",
	"column_width": "column_width",
	"foreground": "fg",
	"selection_background": "selection_bg",
	"selection_foreground": "selection_fg",
	"cursor_color": "cursor",
	"cursor_shape": "cursor_shape",
	"text_outline": "text_outline",
	"text_outline_width": "text_outline_width",
	"text_outline_color": "text_outline_color",
	"clipboard_read": "clipboard_read",
	"clipboard_write": "clipboard_write",
	"open_hyperlinks": "open_hyperlinks",
}
const BACKGROUND_FIELDS := { "color": "bg", "alpha": "background_opacity" }
const EFFECT_FIELDS := {
	"typing_pane_zoom": ["scale"],
	"cursor_trail": ["style", "delay_ms", "decay", "start_threshold"],
	"typing_particles": ["preset", "amount", "scale"],
}


# Native renderer compatibility: positional faces stay internal to the bridge.
func compiled_font_paths() -> PackedStringArray:
	if font_regular_path.is_empty():
		return PackedStringArray()
	return PackedStringArray(
		[font_regular_path, font_bold_path, font_italic_path, font_bold_italic_path]
	)


func to_config() -> ConfigFile:
	var result := ConfigFile.new()
	result.set_value("terminal", "font_paths", compiled_font_paths())
	for property in FIELDS:
		result.set_value(
			"terminal",
			FIELDS[property],
			"#" + get(property).to_html() if get(property) is Color else get(property),
		)
	for property in BACKGROUND_FIELDS:
		result.set_value(
			"terminal",
			BACKGROUND_FIELDS[property],
			(
				"#" + background.get(property).to_html()
				if background.get(property) is Color
				else background.get(property)
			),
		)
	result.set_value(
		"terminal",
		"ansi",
		Array(palette).map(
			func(color):
				return "#" + color.to_html(),
		),
	)
	for index in palette_overrides:
		result.set_value("terminal", "color%d" % index, "#" + palette_overrides[index].to_html())
	for group in EFFECT_FIELDS:
		for property in EFFECT_FIELDS[group]:
			var value = effects.get(group).get(property)
			result.set_value(
				"terminal.effects." + group,
				property,
				"#" + value.to_html() if value is Color else value,
			)
	for style_name in ["smear", "blaze", "lightning"]:
		var options: Dictionary = effects.cursor_trail.get(style_name)
		for key in options:
			var value = options[key]
			result.set_value("terminal.effects.cursor_trail." + style_name, key, "#" + value.to_html() if value is Color else value)
	for property in ADVANCED_FIELDS:
		result.set_value("terminal", property, _copy_value(get(property)))
	return result


func overlay(config: ConfigFile) -> void:
	for property in ADVANCED_FIELDS:
		if config.has_section_key("terminal", property):
			set(property, _copy_value(config.get_value("terminal", property)))
	# Keep existing .conf presets readable; named settings below take precedence.
	if config.has_section_key("terminal", "font_paths"):
		var paths = config.get_value("terminal", "font_paths")
		var fields := [
			"font_regular_path",
			"font_bold_path",
			"font_italic_path",
			"font_bold_italic_path",
		]
		for i in fields.size():
			set(fields[i], str(paths[i]) if i < paths.size() else "")
	for property in FIELDS:
		if config.has_section_key("terminal", FIELDS[property]):
			var value = config.get_value("terminal", FIELDS[property])
			if get(property) is Color:
				value = _color(value)
			set(property, value)
	for property in BACKGROUND_FIELDS:
		if config.has_section_key("terminal", BACKGROUND_FIELDS[property]):
			var value = config.get_value("terminal", BACKGROUND_FIELDS[property])
			background.set(property, _color(value) if property == "color" else value)
	for group in EFFECT_FIELDS:
		for property in EFFECT_FIELDS[group]:
			if config.has_section_key("terminal.effects." + group, property):
				var value = config.get_value("terminal.effects." + group, property)
				effects.get(group).set(property, _color(value) if property == "color" else value)
	for style_name in ["smear", "blaze", "lightning"]:
		var options: Dictionary = effects.cursor_trail.get(style_name)
		for key in options:
			if config.has_section_key("terminal.effects.cursor_trail." + style_name, key):
				var value = config.get_value("terminal.effects.cursor_trail." + style_name, key)
				options[key] = _color(value) if options[key] is Color else value
	if config.has_section_key("terminal", "ansi"):
		var values = config.get_value("terminal", "ansi")
		for i in mini(values.size(), 16):
			palette[i] = _color(values[i])
	if config.has_section("terminal"):
		for key in config.get_section_keys("terminal"):
			if key.begins_with("color") and key.substr(5).is_valid_int():
				palette_overrides[int(key.substr(5))] = _color(config.get_value("terminal", key))


static func _color(value: Variant) -> Color:
	if value is Color:
		return value
	if value == null or str(value) == "none":
		return Color.TRANSPARENT
	return Color(str(value))


func apply_spawn(terminal: Node) -> void:
	for property in [
		"font_family",
		"font_fallbacks",
		"font_size",
		"ligatures",
		"clipboard_write",
		"open_hyperlinks",
	]:
		terminal.set(property, get(property))
	terminal.set("font_paths", compiled_font_paths())
	apply_live(terminal)


func apply_live(terminal: Node) -> void:
	terminal.set("ligatures", ligatures)
	terminal.set("clipboard_write", clipboard_write)
	terminal.set("clipboard_read", { "deny": 0, "ask": 1, "allow": 2 }[clipboard_read])
	terminal.configure_advanced(compiled_advanced())
	var old_handler: Callable = terminal.get_meta("graffitty_link_handler", Callable())
	if old_handler.is_valid() and terminal.hyperlink_activated.is_connected(old_handler):
		terminal.hyperlink_activated.disconnect(old_handler)
	if open_hyperlinks and hyperlink_handler.is_valid():
		terminal.hyperlink_activated.connect(hyperlink_handler, CONNECT_DEFERRED)
	terminal.set_meta("graffitty_link_handler", hyperlink_handler)
	terminal.set("open_hyperlinks", open_hyperlinks and not hyperlink_handler.is_valid())
	# Terminal-action shortcuts come from client.toml [bindings].
	terminal.set("use_custom_key_bindings", true)
	var user_config := load("res://config/UserConfig.gd")
	terminal.set("key_bindings", user_config.terminal_key_bindings(OS.get_cmdline_user_args()))
	terminal.set("key_binding_conditions", user_config.terminal_key_conditions(OS.get_cmdline_user_args()))


## Wire all supported native-node settings directly. A 3D world can draw the
## background separately and call apply_live() for behavior while owning rendering.
func apply_to(terminal: Node) -> void:
	if not terminal.is_inside_tree():
		apply_spawn(terminal)
	else:
		apply_live(terminal)
	var paths := compiled_font_paths()
	terminal.set_live_font_config(paths, font_family, font_fallbacks)
	terminal.set_live_font_size(font_size)
	terminal.set_live_cell_metrics(float(terminal.get("cell_padding")), line_height, column_width)
	terminal.set_selection_colors(selection_background, selection_foreground)
	terminal.set_live_cursor_shape(
		{ "auto": 0, "block": 1, "beam": 2, "bar": 2, "underline": 3, "hollow": 4 }[cursor_shape]
	)
	terminal.set_colors(background.color, foreground, cursor_color, palette)
	for index in palette_overrides:
		terminal.set_palette_color(index, palette_overrides[index])
	terminal.set_live_background_opacity(background.alpha)


## Apply only terminal-centric overlays. Camera, sheet shape and timing
## remain in the world's effect configuration. The world may skip this entirely.
func apply_effects(world_effects: RefCounted) -> void:
	world_effects.set_option("scene.typing", "pane_zoom", effects.typing_pane_zoom.scale)
	world_effects.set_option("scene.cursor_trail", "style", effects.cursor_trail.style)
	for style_name in ["smear", "blaze", "lightning"]:
		for key in effects.cursor_trail.get(style_name):
			var value = effects.cursor_trail.get(style_name)[key]
			world_effects.set_option("scene.cursor_trail." + style_name, key, "#" + value.to_html() if value is Color else value)
	world_effects.set_option("scene.cursor_trail", "delay", effects.cursor_trail.delay_ms)
	world_effects.set_option("scene.cursor_trail", "decay", effects.cursor_trail.decay)
	world_effects.set_option("scene.cursor_trail", "start_threshold", effects.cursor_trail.start_threshold)
	world_effects.set_option("scene.typing", "particles_amount", effects.typing_particles.amount)
	world_effects.set_option("scene.typing", "particles_scale", effects.typing_particles.scale)
	var active_state: String = str(world_effects.behavior.active_state)
	world_effects.set_option("state." + active_state, "typing.particles", effects.typing_particles.preset)
