extends "res://tests/unit/test_case.gd"
const Summary := preload("res://scenes/TabListSummary.gd")
func test_agent_groups_preserve_provider_state_and_titles() -> void:
 var groups := Summary.agents([
  {"provider":"claude", "status":"busy", "title":"Build"},
  {"provider":"claude", "status":"running", "title":"Tests"},
  {"provider":"claude", "status":"idle", "title":"Review"},
  {"provider":"codex", "status":"running", "title":"API"},
  {"provider":"shell", "status":"idle"}, {},
 ])
 expect(groups.size() == 3, "Shells excluded, providers and statuses remain distinct")
 var running: Dictionary = groups.filter(func(g): return g.provider == "claude" and g.status == "running")[0]
 expect(running.count == 2 and running.titles == ["Build", "Tests"], "Equivalent busy states group without losing pane details")

func test_dropdown_reuses_animated_badges_after_resources() -> void:
 var list := preload("res://scenes/TabListRows.gd").new()
 list._ready()
 var font := ThemeDB.fallback_font
 var item := {"id":1, "title":"Workspace", "agents":Summary.agents([{"provider":"codex", "status":"running", "title":"Pane"}])}
 list.populate([item], 1, font, 16, Color.WHITE, Color.BLACK)
 var row: Button = list.rows[0]
 var detail: Control = row.get_meta("detail")
 var group: Control = detail.get_child(3)
 var badge: Node = group.get_child(0)
 expect(badge.spinning and badge.status_name == "running", "Agent badge after pane count, CPU and RAM uses the shared spinner")
 list.populate([item], 1, font, 16, Color.WHITE, Color.BLACK)
 expect(detail.get_child(3).get_child(0) == badge, "Polling retains the badge and its animation phase")
 item.agents = []
 list.populate([item], 1, font, 16, Color.WHITE, Color.BLACK)
 expect(detail.get_child_count() == 3, "Exited agents leave no stale badges")
 list.free()
func test_tab_resources_sum_panes_and_mark_missing_samples() -> void:
 var pane := {"status":"running", "cpu_valid":true, "cpu_percent":12.5, "memory_current":104857600}
 expect(Summary.resources([pane,pane]) == {"cpu":"25%", "ram":"200 MiB"}, "Tab totals include every pane before rounding")
 expect(Summary.resources([pane,{}]) == {"cpu":"≥ 13%", "ram":"≥ 100 MiB"}, "Partial totals are explicitly marked and rounded")
 expect(Summary.resources([{}]) == {"cpu":"—", "ram":"—"}, "Unknown samples are not zero")
