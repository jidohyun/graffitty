extends "../../../../tests/llm-e2e/replay/replay.gd"


func play() -> void:
	await camera_at_rest()
	var chromium: Node = await host.create_chromium_session("about:blank")
	if not check(chromium != null, "Owner creates the resource monitor fixture"): return
	var monitor: Node = chromium.resource_monitor
	check(monitor != null, "Chromium owns a resource monitor")
	if monitor == null: return
	monitor.set_enabled(false)
	var until := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < until:
		await process_frame
	check(chromium.chromium_ready, "Chromium fixture starts")
	if not chromium.chromium_ready:
		chromium.close()
		return
	# This native sampler is test instrumentation only; chromium monitoring uses
	# Chromium on all platforms. Compare idle CPU with monitoring off/on on macOS.
	var sampler: RefCounted
	if OS.get_name() == "macOS" and "--benchmark" in OS.get_cmdline_user_args():
		await hold(12.0) # Exclude Chromium startup from the idle overhead comparison.
		sampler = ClassDB.instantiate("ResourceMonitorService")
		sampler.register_terminal(987654, chromium.pid, 1.0, true)
		await hold(3.0)
		var before: Dictionary = sampler.snapshot(987654)
		await hold(15.0)
		var after: Dictionary = sampler.snapshot(987654)
		print("MONITOR_DISABLED_CPU_SECONDS ", float(after.get("cpu_time", 0)) - float(before.get("cpu_time", 0)))
	monitor.set_enabled(true)
	until = Time.get_ticks_msec() + 20000
	# Native CPU percentages need two samples even after memory becomes ready.
	while (monitor.status != "running" or not monitor.cpu_valid) and Time.get_ticks_msec() < until:
		await process_frame
	var data: Dictionary = monitor.snapshot()
	check(data.get("backend") in ["darwin-rusage-v4", "linux-cgroup-v2", "windows-job-object"], "Payload comes from the owner's native sampler")
	check(data.get("cpu_valid", false) or (data.get("coverage_gap", false) and data.get("cpu_percent_partial") != null), "CPU is valid or explicitly partial")
	print("CHROMIUM_SAMPLE ", {"cpu_percent": data.get("cpu_percent"), "cpu_percent_partial": data.get("cpu_percent_partial"), "process_count": data.get("process_count"), "sample_ms": data.get("sample_ms")})
	check(int(data.get("process_count", 0)) > 1, "Includes helper processes")
	check(int(data.get("memory_current", 0)) > 0, "Memory footprint is populated")
	check(int(data.get("root_pid", -1)) == chromium.pid, "Only this Chromium host is tracked")
	check(data.get("cpu_time") != null and float(data.cpu_time) >= 0, "Owner provides cumulative CPU time")
	check(monitor.interval_seconds == 1.0, "Chromium snapshots update every second")
	var sequence: int = int(data.get("sample_sequence", -1))
	await hold(3.0)
	check(int(monitor.snapshot().get("sample_sequence", -1)) > sequence, "Persistent tracker continues producing new samples")
	if sampler != null:
		var before: Dictionary = sampler.snapshot(987654)
		await hold(15.0)
		var after: Dictionary = sampler.snapshot(987654)
		print("MONITOR_ENABLED_CPU_SECONDS ", float(after.get("cpu_time", 0)) - float(before.get("cpu_time", 0)))
		monitor.pause()
		await hold(7.0) # Allow any in-flight sample to finish and detach.
		before = sampler.snapshot(987654)
		await hold(15.0)
		after = sampler.snapshot(987654)
		print("MONITOR_PAUSED_CPU_SECONDS ", float(after.get("cpu_time", 0)) - float(before.get("cpu_time", 0)))
		sampler.remove_terminal(987654)
	var pane: Control = host.workspace_view.panes["%%%d" % chromium.session_id]
	check(not pane.header.has_node("Monitor"), "Chromium header omits the monitor shortcut")
	pane._title_menu_action(1)
	check(host.pane_status_visible and host.pane_focus == pane.key, "Chromium monitor context action focuses and opens its panel")
	host.workspace_view._update_monitor()
	var monitor_view: Control = preload("res://scenes/PaneStatusDialog.gd").find(host).view
	monitor_view.render_now()
	check("Chromium" in monitor_view.get_tooltip(monitor_view.hit_rect("pane").get_center()), "Monitor follows chromium focus")
	monitor.pause()
	var revision: int = monitor.snapshot().revision
	await hold(7.0)
	check(monitor.status == "paused" and monitor.snapshot().revision == revision, "Paused samples stop updating")
	monitor.resume()
	until = Time.get_ticks_msec() + 12000
	while monitor.status != "running" and Time.get_ticks_msec() < until:
		await process_frame
	check(monitor.status == "running", "Resuming reattaches the tracker")
	chromium.close()
