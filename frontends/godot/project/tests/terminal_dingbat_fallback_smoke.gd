extends SceneTree
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(800,500)
	root.add_child(terminal)
	await process_frame
	await process_frame
	terminal.remote_feed("✢✳✻✽ ⏰".to_utf8_buffer(),80,24)
	var stars := 0
	for cell in terminal.cell_glyphs():
		if int(cell.cp) in [0x2722,0x2733,0x273b,0x273d]:
			if cell.wide:
				assert(int(cell.font)==6,"Explicit emoji keeps color fallback")
			else:
				assert(int(cell.font)==5,"Text dingbats use one-cell JuliaMono glyphs")
				stars += 1
		if int(cell.cp)==0x23f0:
			assert(int(cell.font)==6,"Wide clock retains emoji presentation")
	assert(stars==4,"All four text spinner symbols checked")
	print("TERMINAL_DINGBAT_FALLBACK_PASS")
	terminal.free()
	await process_frame
	quit()
