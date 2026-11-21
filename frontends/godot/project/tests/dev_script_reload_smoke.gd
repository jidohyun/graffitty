extends SceneTree
var watcher: Node
func _initialize():
 run.call_deferred()
func run():
 var folder := "user://dev-reload-test"
 DirAccess.make_dir_recursive_absolute(folder)
 var path := folder.path_join("Example.gd")
 var original := "extends RefCounted\nvar count := 4\nfunc value(): return count + 1\n"
 FileAccess.open(path, FileAccess.WRITE).store_string(original)
 var script = load(path)
 var instance = script.new()
 instance.count = 20
 watcher = load("res://scenes/DevScriptReload.gd").new()
 watcher.roots = PackedStringArray([folder])
 root.add_child(watcher)
 FileAccess.open(path, FileAccess.WRITE).store_string(original.replace("count + 1", "count + 3"))
 watcher.poll()
 assert(instance.value() == 21)
 watcher.poll()
 assert(instance.value() == 23)
 assert(instance.count == 20)
 DirAccess.remove_absolute(path)
 DirAccess.remove_absolute(folder)
 print("DEV_RELOAD_PASS")
 quit()
