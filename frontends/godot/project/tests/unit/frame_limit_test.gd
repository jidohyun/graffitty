extends "res://tests/unit/test_case.gd"
## The frame cap follows the application's focus, not one workspace window's.

func test_a_focused_dialog_keeps_the_full_frame_rate() -> void:
	var application: Node = Engine.get_main_loop().root.get_node("TerminalApplication")
	var windows: Array[Node] = application.hosts
	var saved_cap := Engine.max_fps
	# A focused native dialog leaves every workspace window unfocused.
	application.hosts = [] as Array[Node]
	application.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	expect(Engine.max_fps == application.max_fps, "A focused dialog keeps the full frame rate: %d" % Engine.max_fps)
	application.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	expect(Engine.max_fps == mini(application.inactive_max_fps, application.max_fps), "A background application uses the inactive cap: %d" % Engine.max_fps)
	application.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	application.hosts = windows
	Engine.max_fps = saved_cap
