extends "res://tests/mods_fixture.gd"
func run() -> void:
 setup()
 for name in ["sessions", "agents", "pane-status", "resource-monitor", "status-line"]:
  var dialog: Window = PanelWindow.open(host, name)
  await settle()
  var expected := "bottom" if name in ["status-line", "resource-monitor"] else "left"
  check(dialog._desktop.side == expected, name + " defaults to " + expected)
  check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), name + " renders docked")
  check(dialog._desktop.material is ShaderMaterial, name + " blurs the dock backdrop")
  check(dialog.background_opacity < 1.0 and is_equal_approx(dialog._desktop.get_theme_stylebox("panel").bg_color.a, dialog.background_opacity), name + " keeps the dock surface translucent")
  dialog.background_blur_radius = 24.0
  dialog.apply_background()
  check(is_equal_approx(dialog._desktop.material.get_shader_parameter("radius"), 24.0 * dialog._desktop.get_window().content_scale_factor), name + " applies configured blur level")
  dialog.float_native()
  await settle()
  check(dialog._desktop.side.is_empty(), name + " can float")
  check(dialog.default_dock_side().is_empty(), name + " preserves deliberate floating placement")
  dialog._close_panel()
  await settle()
 finish("MOD_DEFAULTS")
