extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var chrome := Control.new()
	root.add_child(chrome)
	chrome.position = Vector2(0, 42)
	var viewport := SubViewport.new()
	root.add_child(viewport)
	var canvas := Control.new()
	viewport.add_child(canvas)
	var failures := 0
	for script in [preload("res://scenes/AgentGraphOverlay.gd"), preload("res://scenes/WorkspaceChromiumLinks.gd")]:
		var links = script.new()
		chrome.add_child(links)
		links.mount_wire_layer(canvas, func(point): return point)
		if links.wire_layer.transform != Transform2D.IDENTITY:
			failures += 1
			print("FAIL Wire inherited screen-space title offset: ", links.wire_layer.transform)
		# Repeated mounting must not introduce another transform.
		links.mount_wire_layer(canvas, func(point): return point)
		if links.wire_layer.transform != Transform2D.IDENTITY: failures += 1
		links.wire_layer.queue_free()
		links.queue_free()
	await process_frame
	print("WIRE_MOUNT_PASS" if failures == 0 else "WIRE_MOUNT_FAIL")
	quit(0 if failures == 0 else 1)
