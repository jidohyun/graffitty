extends "terminal_grid_owner_smoke.gd"

func play() -> void:
	await super.play()
	var terminal = host.sessions[host.active_session_id].term
	root.size = Vector2i(1280, 800)
	root.content_scale_size = Vector2i(1280, 800)
	host.workspace_view.show_main()
	terminal.send_text("printf '\\033[2J\\033[HServer font rendering: ABC xyz 0123456789\\n한글 폰트는 서버에서 전달됩니다.\\n\\033[1mBold text 굵은 글씨\\033[0m\\n\\033[3mItalic text\\033[0m  🚀 😀 ✓\\n'\n")
	await hold(0.5)
	var image: Image = await screen_image()
	check(not image.is_empty(), "Metal renders the downloaded font set")
	var path := OS.get_temp_dir().path_join("graffitty-server-font-render.png")
	check(image.save_png(path) == OK, "Save server-font rendering evidence")
	print("SERVER_FONT_RENDER_IMAGE ", path)
