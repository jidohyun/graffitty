extends "res://tests/scatter_residual_smoke.gd"
func play() -> void:
 await camera_at_rest()
 check(host.tab_transition_effect() == "push_pull", "Flat defaults to Push/Pull")
 var entries: Array = host.menu_entries.filter(func(entry): return entry.label.begins_with("View::Tab Transition::"))
 check(entries.map(func(entry): return entry.label) == ["View::Tab Transition::None", "View::Tab Transition::Scatter", "View::Tab Transition::Push/Pull"], "Menu exposes None, Scatter, and Push/Pull")
 for entry in entries:
  host._run_menu_action(entry)
  check(entry.checked.call(host), entry.label + " selects and checks its effect")
  check(entries.filter(func(item): return item.checked.call(host)).size() == 1, "Exactly one effect is checked")
  check(host.world.tab_fx == (host.tab_transition_effect() != "none"), "Selection immediately updates renderer")
