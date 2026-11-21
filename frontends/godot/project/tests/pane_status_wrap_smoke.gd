extends "res://tests/mods_fixture.gd"
## Check Pane Status in a narrow sidebar.
##
## Icon rows keep their height and stay separate. A missing-monitor
## message wraps below the pane row without covering it.

func run() -> void:
	setup()
	var dialog: Window = PanelWindow.open(host, "pane-status")
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Pane Status loads: " + dialog.view.last_error())
	dialog.float_native()
	await settle()
	dialog.view.size = Vector2(150, 400)
	await settle()
	dialog.view.render_now()
	var previous := Rect2()
	var overlaps := []
	for key in ["pane", "metric-cpu", "metric-memory", "metric-peak", "metric-processes"]:
		var rect: Rect2 = dialog.view.hit_rect(key)
		check(rect.size.y >= 18, "%s keeps its row height: %s" % [key, rect])
		if previous.has_area() and rect.position.y < previous.end.y - .5: overlaps.append("%s %s after %s" % [key, rect, previous])
		previous = rect
	check(overlaps.is_empty(), "No row starts above the end of the row before it: %s" % [overlaps])
	check("PID 123" in dialog.view.get_tooltip(dialog.view.hit_rect("metric-processes").get_center()), "The process row names the root PID in its tooltip")
	check(not has_text(dialog, "PID"), "Labels live in tooltips, not beside the values: %s" % [texts(dialog)])
	# Draw a nowrap label first, as the status line or a compact row would, so
	# the shared paragraph is dirty, then show a pane without a monitor.
	var sample: Node = host.sample
	host.sample = null
	app.mods.publish_resources(host)
	await settle()
	dialog.view.render_now()
	var pane: Rect2 = dialog.view.hit_rect("pane")
	var message: Rect2 = dialog.view.hit_rect("message")
	check(message.size.y > 30, "The unavailable explanation wraps onto several rows: %s" % [message])
	check(message.position.y >= pane.end.y - .5, "The explanation starts below the pane row: %s after %s" % [message, pane])
	host.sample = sample
	dialog.queue_free()
	await settle()
	finish("PANE_STATUS_WRAP")
