extends "res://tests/unit/test_case.gd"
const Frame := preload("res://scenes/WindowFrameLinux.gd")


func test_linux_frame_modes() -> void:
	for backend in ["X11", "Wayland"]:
		for preference in ["client", "system"]:
			for transparent in [false, true]:
				for mode in [Window.MODE_WINDOWED, Window.MODE_MAXIMIZED, Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]:
					for tiled in [false, true]:
						var expected := Frame.Mode.SYSTEM
						if preference == "client":
							expected = Frame.Mode.SQUARE
							if mode == Window.MODE_WINDOWED and not tiled:
								expected = Frame.Mode.ROUNDED if transparent else Frame.Mode.OPAQUE
						expect(Frame.frame_mode(backend, transparent, mode, tiled, preference) == expected,
							"%s alpha=%s mode=%s tiled=%s decorations=%s" % [backend, transparent, mode, tiled, preference])
	for backend in ["macOS", "Windows", "headless", "Android"]:
		expect(Frame.frame_mode(backend, true, Window.MODE_WINDOWED, false, "client") == Frame.Mode.SYSTEM,
			"Linux decorations apply only to Linux display drivers")


func test_desktop_button_layout() -> void:
	expect(Frame.button_layout("appmenu:close") == [[], ["minimize", "maximize", "close"]], "Right-side default")
	expect(Frame.button_layout("close:") == [["close", "minimize", "maximize"], []], "Left-side controls")
	expect(Frame.button_layout("close,maximize:minimize") == [["close", "maximize"], ["minimize"]], "Split controls")
