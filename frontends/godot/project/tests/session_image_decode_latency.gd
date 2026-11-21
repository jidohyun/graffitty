extends SceneTree
## Companion to session_image_latency.py: the actual native client's VT/PNG path.
## Headless, synchronous parsing only; excludes GPU upload and presentation.
func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var directory := OS.get_cmdline_user_args()[0]
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("results.json")))
	var results: Array = []
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(1000, 700)
	root.add_child(terminal)
	await process_frame
	await process_frame
	for row in report.rows:
		if row.transport != "ipc": continue
		for filename in ["received.vt", "reconnect.vt"]:
			var bytes := FileAccess.get_file_as_bytes(directory.path_join(row.case).path_join(filename))
			assert(not bytes.is_empty())
			var samples: Array[float] = []
			for _sample in range(7):
				var started := Time.get_ticks_usec()
				for offset in range(0, bytes.size(), 1048576):
					terminal.remote_feed_stream(bytes.slice(offset, mini(offset + 1048576, bytes.size())), 80, 24, offset == 0, false)
				samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
				if terminal.image_placements().size() != 1:
					push_error("Decoded image placement missing: " + str(row.case))
					quit(1)
					return
			samples.sort()
			var result := {"case": row.case, "payload": filename, "bytes": bytes.size(), "median_ms": samples[3], "max_ms": samples[6], "samples": 7}
			results.append(result)
			print(JSON.stringify(result))
	var file := FileAccess.open(directory.path_join("client-decode.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"excludes": "GPU upload and presentation; includes native client VT parsing, PNG decode and 1 MiB Godot packet copies", "rows": results}, "  "))
	file.close()
	terminal.queue_free()
	await process_frame
	quit()
