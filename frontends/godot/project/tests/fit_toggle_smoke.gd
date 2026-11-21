extends "../../../../tests/llm-e2e/replay/replay.gd"

func assert_frame(view: Control, expected: Dictionary, label: String) -> void:
 check(view.navigation_center.distance_to(expected.center) < .01 and absf(view.navigation_zoom - expected.zoom) < .0001, label)

func play() -> void:
 await camera_at_rest()
 var view: Control = host.workspace_view
 var key: String = host.pane_focus
 view.show_main()
 var main: Dictionary = view.main_frame()
 view.toggle_fit_pane(key)
 view._inspect_tween.custom_step(.31)
 var fitted := {"center": view.navigation_center, "zoom": view.navigation_zoom}
 check(absf(main.zoom-fitted.zoom) > .01, "Main pane toggles to a distinct zoom")
 view.toggle_fit_pane(key)
 await hold(.4)
 assert_frame(view, main, "Second settled press returns to Main")
 # Two rapid presses used to lose the fitted destination and capture the
 # partially returned camera as the next remembered view.
 for i in 6:
  view.toggle_fit_pane(key)
  view._inspect_tween.custom_step(.07)
 view.toggle_fit_pane(key)
 await hold(.4)
 assert_frame(view, fitted, "Seventh rapid press reaches the original fitted endpoint")
 view.toggle_fit_pane(key)
 await hold(.4)
 assert_frame(view, main, "Eighth press returns to the original Main endpoint")
 check(not view.overview, "Returning to Main restores Main mode")
 # Intentional navigation establishes a new pair.
 view.zoom_workspace(.7, view.size*.5)
 var custom := {"center": view.navigation_center, "zoom": view.navigation_zoom}
 view.toggle_fit_pane(key)
 view._inspect_tween.custom_step(.07)
 view.toggle_fit_pane(key)
 await hold(.4)
 assert_frame(view, custom, "Manual navigation becomes the new return endpoint")
 view.fit_to_main_area()
 await hold(.4)
 assert_frame(view, main, "Fit Main reaches the main frame")
 check(not view.overview, "Fit Main restores Main mode")
 view.fit_to_main_area()
 await hold(.4)
 assert_frame(view, custom, "Repeating Fit Main restores the previous overview")
 check(view.overview, "Restoring overview preserves navigation mode")
 for i in 6:
  view.fit_to_main_area()
  view._inspect_tween.custom_step(.07)
 view.fit_to_main_area()
 await hold(.4)
 assert_frame(view, main, "Rapid Fit Main presses retain the intended endpoints")
 view.fit_to_main_area()
 await hold(.4)
 assert_frame(view, custom, "Fit Main can reverse after a rapid sequence")
 if OS.get_name() == "macOS":
  await keys("cmd+shift+enter")
  await hold(.4)
  assert_frame(view, main, "Default Command-Shift-Enter fits Main")
  await keys("cmd+shift+enter")
  await hold(.4)
  assert_frame(view, custom, "Default shortcut toggles back to overview")
