extends RefCounted
## A user's tiling manager must not override the demo's native window bounds.
static func float_owned_window(pid: int) -> bool:
	var aerospace := "/opt/homebrew/bin/aerospace"
	if not FileAccess.file_exists(aerospace): return true
	for attempt in 50:
		var result := []
		var code := OS.execute(aerospace, ["list-windows", "--monitor", "all", "--pid", str(pid),
			"--format", "%{window-id}"], result, true)
		if code != 0:
			print("Native layout query failed: ", result)
			return false
		var ids := str(result[0]).strip_edges().split("\n", false)
		if ids.size() == 1 and ids[0].is_valid_int():
			return OS.execute(aerospace, ["layout", "floating", "--window-id", ids[0]]) == 0
		OS.delay_msec(50)
	print("Native layout: no unique window for private PID ", pid)
	return false
