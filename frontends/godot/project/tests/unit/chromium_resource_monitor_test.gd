extends "res://tests/unit/test_case.gd"
const Monitor := preload("res://scenes/ChromiumResourceMonitor.gd")
const Host := preload("res://scenes/TerminalHost.gd")
const Chromium := preload("res://scenes/ChromiumSession.gd")
const View := preload("res://scenes/WorkspaceView.gd")

func test_chromium_cadence_is_independent_of_terminal_config() -> void:
	var config := ConfigFile.new()
	config.set_value("resource_monitor", "interval", "5s")
	var chromium := Monitor.new()
	chromium.configure(null, config)
	var terminal := preload("res://scenes/TerminalResourceMonitor.gd").new()
	terminal.configure(null, 1, null, config)
	expect(chromium.interval_seconds == 1.0, "Chromium reads its persistent tracker every second")
	expect(terminal.interval_seconds == 5.0, "Terminal retains five-second collection")
	chromium.free()
	terminal.free()

func sample(memory: int) -> Dictionary:
	return {"result": {"backend": "darwin-rusage-v4", "revision": memory, "status": "running", "root_pid": 4321, "process_count": 3, "memory_current": memory, "cpu_time": 12.0, "cpu_percent": 12.5, "cpu_valid": true}}

func test_peak_reset_pause_and_unknown_metrics() -> void:
	var monitor := Monitor.new()
	monitor._accept_sample(sample(1000))
	monitor._accept_sample(sample(500))
	expect(monitor.snapshot().memory_peak_observed == 1000, "Peak is largest observed sample")
	expect(monitor.cpu_time == 12.0 and monitor.snapshot().cpu_time == 12.0, "Owner cumulative CPU reaches the chromium readout")
	monitor.pause()
	expect(monitor.status == "paused" and not monitor.cpu_valid, "Pause marks old CPU stale")
	monitor.reset()
	expect(monitor.status == "paused" and monitor._peak == 0, "Reset preserves pause and clears peak")
	monitor.resume()
	monitor._accept_sample(sample(200))
	expect(monitor.snapshot().memory_peak_observed == 200, "Reset starts a new observation epoch")
	monitor._accept_sample({"error": "tracker unavailable"})
	expect(monitor.status == "unavailable" and not monitor.cpu_valid, "Errors do not masquerade as zero CPU")
	expect(monitor.snapshot().memory_current == 200, "Error preserves the last known memory sample")
	monitor.set_enabled(false)
	expect(monitor.status == "disabled", "Disabling changes monitor state")
	monitor.set_enabled(true)
	expect(monitor.status == "starting" and monitor._peak == 0, "Reenable resets the epoch")
	monitor.free()

class SampleChromium extends "res://scenes/ChromiumSession.gd":
	var requests := 0
	func request(_action: String, _args: Dictionary = {}, _timeout_ms := 20000) -> Dictionary:
		requests += 1
		return {"result": {"root_pid": pid, "status": "running", "revision": requests,
			"memory_current": 4096, "process_count": 2, "cpu_valid": true, "cpu_percent": 3.0}}

func test_secondary_browser_window_samples_its_owner_and_releases_the_tracker() -> void:
	var chromium := SampleChromium.new()
	chromium.main_window = false
	chromium.pid = 4321
	chromium.chromium_ready = true
	var monitor := Monitor.new()
	monitor.configure(chromium, ConfigFile.new())
	monitor._poll()
	expect(chromium.requests == 1 and monitor.status == "running" and monitor.memory_current == 4096,
		"Secondary browser panes receive real owner resource samples rather than remaining at starting")
	monitor.pause()
	expect(chromium._queue.size() == 1 and chromium._queue[0].action == "resources" and chromium._queue[0].enabled == false,
		"Pausing a secondary pane releases its own owner-side tracker")
	monitor.free()
	chromium.free()

func test_pending_browser_identity_is_not_reported_as_exited() -> void:
	var chromium := SampleChromium.new()
	var monitor := Monitor.new()
	monitor.configure(chromium, ConfigFile.new())
	monitor._poll()
	expect(monitor.status == "starting" and chromium.requests == 0,
		"A pending owner PID waits for startup instead of permanently stopping the sampler")
	chromium.pid = 4321
	chromium.chromium_ready = true
	monitor._poll()
	expect(monitor.status == "running", "A later owner identity starts sampling")
	chromium._closing = true
	monitor._poll()
	expect(monitor.status == "exited", "An actually closed browser still stops sampling")
	monitor.free()
	chromium.free()

func test_monitor_follows_chromium_and_terminal_focus() -> void:
	var host := Host.new()
	var chromium := Chromium.new()
	var chromium_monitor := Monitor.new()
	chromium_monitor._accept_sample(sample(1000))
	chromium.resource_monitor = chromium_monitor
	host.chromiums[7] = chromium
	var terminal_monitor := Monitor.new()
	host.sessions[2] = {"resource_monitor": terminal_monitor}
	host.active_session_id = 2
	var describe := func() -> String: return preload("res://scenes/mods/ModService.gd")._resources(host).tooltip
	host.pane_focus = "%7"
	expect("Chromium 7" in describe.call(), "Chromium focus selects its own session")
	expect("Chromium host PID 4321" in describe.call(), "Chromium root is not labelled a shell")
	host.pane_focus = "%2"
	expect("Pane %2" in describe.call(), "Terminal focus restores the pane monitor")
	chromium_monitor._accept_sample({"error": "Tracker unavailable"})
	host.pane_focus = "%7"
	expect("Tracker unavailable" in describe.call() and not "MiB" in describe.call(), "Unavailable accounting must not display zero usage")
	chromium_monitor.free()
	terminal_monitor.free()
	chromium.free()
	host.free()
