extends RefCounted
## Convert server cell deltas into a presentation-only VT stream. The native
## Terminal draws/shapes it with the same fonts as a local terminal.
const INPUT_MODES := [1, 9, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 2004]


static func color_sgr(value: String, foreground: bool) -> String:
	var c := Color(value)
	return "%d;2;%d;%d;%d" % [38 if foreground else 48, c.r8, c.g8, c.b8]


static func encode(frame: Dictionary, updates: Array, reset: bool) -> PackedByteArray:
	# Disable origin/insert/wrap while painting absolute server cell positions.
	var text := "\u001b[?6l\u001b[4l\u001b[?7l\u001b[0m"
	text += "\u001b]10;%s\u0007\u001b]11;%s\u0007" % [frame.foreground, frame.background]
	if reset:
		text += "\u001b[2J"
	for update in updates:
		var row := int(update[0])
		text += "\u001b[%d;1H\u001b[0m\u001b[2K" % (row + 1)
		var next_column := 0
		var previous_style := "0"
		for cell in update[1]:
			var glyph := str(cell[2])
			# A wide glyph's spacer must never overwrite its second column.
			if glyph.is_empty():
				if int(cell[0]) < next_column:
					continue
				glyph = " "
			var style := "0;" + ("39" if cell[3] == frame.foreground else color_sgr(cell[3], true)) + ";" + (
				"49" if cell[4] == frame.background else color_sgr(cell[4], false)
			)
			for pair in [[1, 1], [2, 3], [4, 2], [8, 4], [16, 9]]:
				if int(cell[5]) & pair[0]:
					style += ";%d" % pair[1]
			if int(cell[0]) != next_column:
				text += "\u001b[%d;%dH" % [row + 1, int(cell[0]) + 1]
			if style != previous_style:
				text += "\u001b[%sm" % style
			text += glyph
			previous_style = style
			next_column = int(cell[0]) + int(cell[1])
	text += "\u001b[0m\u001b[?7h\u001b[%d q" % clampi(int(frame.get("cursor_style", 0)), 0, 6)
	if frame.cursor.size() == 2:
		text += "\u001b[%d;%dH\u001b[?25h" % [int(frame.cursor[1]) + 1, int(frame.cursor[0]) + 1]
	else:
		text += "\u001b[?25l"
	for mode in INPUT_MODES:
		text += "\u001b[?%d%s" % [mode, "h" if mode in frame.get("input_modes", []) else "l"]
	text += "\u001b[=%du" % int(frame.get("kitty_keys", 0))
	return text.to_utf8_buffer()
