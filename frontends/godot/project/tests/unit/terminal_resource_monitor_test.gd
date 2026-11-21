extends "res://tests/unit/test_case.gd"

class CountingMonitor extends "res://scenes/TerminalResourceMonitor.gd":
	var copies := 0
	func snapshot() -> Dictionary:
		copies += 1
		return super.snapshot()

class Host extends Node:
	var monitors := {}
	func resource_monitor_for(id: int) -> Node:
		return monitors.get(id)

func test_resource_samples_wait_for_pane_creation_without_becoming_fresh_again() -> void:
	var client := preload("res://scenes/remote/RemoteClient.gd").new()
	client.connection.topology = {"panes": [{"id": 42}]}
	client._resources(42, {"status": "running", "cpu_valid": true, "cpu_percent": 12.0,
		"memory_current": 1024, "sample_age_seconds": 0.5}, 1.0)
	client.pending_resources[42].received -= 2000
	var host := Host.new()
	var monitor := CountingMonitor.new()
	monitor.remote = true
	host.monitors[42] = monitor
	client.host = host
	client._flush_resource_samples()
	var sample := monitor.snapshot()
	expect(sample.cpu_valid and sample.cpu_percent == 12.0 and sample.memory_current == 1024,
		"The first owner sample survives delayed font/pane creation")
	expect(sample.sample_age_seconds >= 2.5 and client.pending_resources.is_empty(),
		"Waiting time is included in the sample age, and the queue drains once")
	client._resources(43, {"status": "running"}, 1.0)
	client._flush_resource_samples()
	expect(client.pending_resources.is_empty(), "Samples for removed panes cannot reach another presentation")
	client._resources(44, {"status": "running"}, 1.0)
	client._resources(44, {"status": "disconnected"}, 1.0)
	expect(client.pending_resources.is_empty(), "Disconnect discards samples even before a pane exists")
	monitor.free()
	host.free()
	client.connection.free()
	client.remember.free()
	client.dialog.free()
	client.endpoint.free()
	client.secret.free()
	client.status.free()
	client.free()

func test_remote_idle_ticks_do_not_copy_the_process_inventory() -> void:
	var monitor := CountingMonitor.new()
	monitor.remote = true
	monitor.apply_remote({"status": "running", "sample_age_seconds": 0.0,
		"processes": [{"pid": 123, "name": "agent"}]}, 1.0)
	monitor.copies = 0
	for tick in 60: monitor._process(1.0 / 60.0)
	expect(monitor.copies == 0, "Fresh samples need only a timestamp check, not sixty deep process-tree copies")
	var statuses := []
	var samples := []
	monitor.state_changed.connect(func(status): statuses.append(status))
	monitor.snapshot_changed.connect(func(data): samples.append(data))
	monitor._snapshot.sample_age_seconds = 4.0
	monitor._process(0.0)
	monitor._process(0.0)
	expect(statuses == ["stale"] and samples.size() == 1 and samples[0].status == "stale",
		"Aging still publishes one stale transition with the full inventory")
	expect(monitor.copies == 1 and samples[0].processes[0].pid == 123, "Only the actual notification copies process data")
	monitor.apply_remote({"status": "running", "sample_age_seconds": 0.0, "processes": []}, 1.0)
	monitor._process(0.0)
	expect(monitor.snapshot().status == "running" and not monitor._reported_stale, "A new owner sample clears staleness")
	monitor.free()
