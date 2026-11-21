extends SceneTree
const Embedded := preload("res://scenes/mods/EmbeddedMod.gd")
var failures := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
 print(("PASS " if ok else "FAIL ") + message)
 if not ok: failures += 1
func run() -> void:
 var tabs := Embedded.create("tab-menu", {"item": {"title": "Editor", "ordinal": 1, "pane_count": 2, "resources": {"cpu": "5%", "ram": "42M"}, "match_indices": [0, 1]}, "font_size": 16, "foreground": "#ffffff", "background": "#202126"})
 root.add_child(tabs)
 tabs.size = Vector2(600, 70)
 var command := Embedded.create("command-line", {"label": "Sessions", "title": "All Sessions", "detail": "", "indices": [0], "font_size": 16, "foreground": "#ffffff", "dim": "#aaaaaa", "address_width": 140, "detail_width": 0})
 root.add_child(command)
 command.size = Vector2(600, 30)
 await process_frame
 tabs.render_now()
 command.render_now()
 check(tabs.last_error().is_empty(), "Tab menu mod renders: " + tabs.last_error())
 check(command.last_error().is_empty(), "Command-line mod renders: " + command.last_error())
 check("5%" in tabs.texts() and tabs.hit_rect("panes").has_area(), "Tab metrics and pane-count hit region survive migration")
 check("All Sessions" in command.texts(), "Command completion text comes from the mod")
 tabs.queue_free()
 command.queue_free()
 await process_frame
 quit(0 if failures == 0 else 1)
