## Lifecycle for the isolated `gft server` a test starts in its own cache
## directory.
##
## The server's holder keeps running after a SIGKILL by design, so tests stop
## the server with SIGTERM (a clean shutdown ends its holder) and then kill
## whatever still names the directory.
##
## A run that was cut short never reaches its cleanup, so `prepare` also
## sweeps directories left by dead runs.
extends RefCounted

const OWNER_FILE := "test-owner.pid"


## Creates a fresh directory under the user cache, after removing leftovers
## from earlier runs with the same prefix whose test process has exited.
static func prepare(prefix: String) -> String:
	var cache := OS.get_cache_dir()
	for name in DirAccess.get_directories_at(cache):
		if not name.begins_with(prefix + "-"): continue
		var path := cache.path_join(name)
		var owner := FileAccess.get_file_as_string(path.path_join(OWNER_FILE)).strip_edges()
		# Directories from before owner files existed have no owner: also stale.
		if owner.is_valid_int() and _alive(owner.to_int()): continue
		stop(-1, path)
	var directory := cache.path_join("%s-%d-%d" % [prefix, OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(directory.path_join(OWNER_FILE), FileAccess.WRITE)
	file.store_string(str(OS.get_process_id()))
	file.close()
	return directory


## Stops the server (and its holder), then removes the directory unless a
## failed run keeps it for inspection (the next run's sweep removes it).
static func stop(server_pid: int, directory: String, keep_files := false) -> void:
	# is_process_running also reaps our exited child; `kill -0` sees a zombie.
	if server_pid > 0 and OS.is_process_running(server_pid):
		OS.execute("kill", ["-TERM", str(server_pid)])
		var deadline := Time.get_ticks_msec() + 3000
		while OS.is_process_running(server_pid) and Time.get_ticks_msec() < deadline: OS.delay_msec(20)
	if not directory.is_empty():
		# Anything still naming the directory (holder, orphaned server) is ours.
		OS.execute("pkill", ["-TERM", "-f", directory])
		OS.delay_msec(200)
		OS.execute("pkill", ["-KILL", "-f", directory])
		if not keep_files: _remove_tree(directory)


static func _alive(pid: int) -> bool:
	return OS.execute("kill", ["-0", str(pid)]) == 0


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for name in DirAccess.get_directories_at(path): _remove_tree(path.path_join(name))
	for name in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(name))
	DirAccess.remove_absolute(path)
