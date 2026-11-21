extends "res://tests/mods_fixture.gd"

func run() -> void:
 setup(true)
 var dialog := preload("res://scenes/MessagesWindow.gd").new()
 root.add_child(dialog)
 dialog.present()
 await settle()
 check(is_equal_approx(dialog.background_opacity, 0.8), "Messages use the same alpha as the status line")
 check(dialog._desktop.material is ShaderMaterial, "Docked messages blur the backdrop")
 check(is_equal_approx(dialog._desktop.get_theme_stylebox("panel").bg_color.a, 0.8), "Docked messages keep their surface translucent")
 dialog.float_native(Vector2(100, 120))
 await settle()
 check(dialog.is_embedded(), "Fixture uses an embedded floating window")
 check(is_instance_valid(dialog._embedded_backdrop) and dialog._embedded_backdrop.visible, "Floating messages blur the parent scene")
 var backdrop: Panel = dialog._embedded_backdrop
 dialog.hide()
 check(not backdrop.visible, "Hidden messages do not leave a blur behind")
 dialog.release()
 await settle()
 check(not is_instance_valid(backdrop), "Closing messages frees the backdrop")
 finish("MESSAGES_BACKDROP")
