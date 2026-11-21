extends SceneTree
## Only owns the standalone fixture process; both platforms execute workspace.gd.
func run(case_name: String) -> void:
	var directory := OS.get_cache_dir().path_join("android-workspace-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	var args := ["exec","--","uv","run",ProjectSettings.globalize_path("res://../../../tests/android/test_android_runtime.py"),"--simulated",case_name,"--output",directory]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--remote-movie="): args.append_array(["--movie",arg.trim_prefix("--remote-movie=")])
	var pid := OS.create_process("mise",args)
	if pid <= 0:
		print("ANDROID_WORKSPACE_FAIL: runner did not start")
		quit(1); return
	while OS.is_process_running(pid): await process_frame
	var path := directory.path_join(case_name).path_join("runtime-state.json")
	var passed := false
	if FileAccess.file_exists(path):
		var result: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		for check in result.get("checks",[]):
			if check not in result.get("failures",[]): print("[replay] PASS ",check)
		for failure in result.get("failures",[]): print("[replay] FAIL ",failure)
		passed = result.get("failures",["missing result"]).is_empty()
	var summary := directory.path_join("results.json")
	if FileAccess.file_exists(summary):
		var results: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(summary))
		passed = passed and results.get(case_name,{}).get("status")=="pass"
	else: passed = false
	var log := directory.path_join(case_name).path_join("client.log")
	if FileAccess.file_exists(log):
		for line in FileAccess.get_file_as_string(log).split("\n"):
			if "AV1_MOVIE_" in line: print(line)
	print("ANDROID_WORKSPACE_%s: %s; evidence %s" % ["PASS" if passed else "FAIL",case_name,directory])
	quit(0 if passed else 1)
