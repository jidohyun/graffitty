extends "res://tests/checkpoint_restore_smoke.gd"

func _initialize() -> void:
	print("CHECKPOINT_USER_DIRECTORY ", JSON.stringify(OS.get_user_data_dir()))
	super._initialize()

func observe_restore(app: Node, snapshot: Dictionary) -> bool:
	for index in app.hosts.size():
		var host: Node = app.hosts[index]
		for browser in host.chromiums.values():
			var result: Dictionary = await browser.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "({title:document.title, fresh:typeof window.unsavedCheckpointMarker==='undefined', stored:localStorage.getItem('checkpoint-window')})", "returnByValue": true}})
			var value: Dictionary = result.get("result", {}).get("result", {}).get("value", {})
			if value.get("title") != "second" or value.get("fresh") != true: return false
			if not OS.get_environment("CHECKPOINT_PROFILES").is_empty() and value.get("stored") != str(index): return false
	FileAccess.open(OS.get_environment("CHECKPOINT_RESTORED"), FileAccess.WRITE).store_string(JSON.stringify(snapshot))
	return true
