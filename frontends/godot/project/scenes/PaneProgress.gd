extends ProgressBar
## Overlay below the header: reporting progress never changes the terminal grid.
var _reported := Vector2i(-1, -2)
func _init() -> void:
	show_percentage = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.y = 3
	add_theme_stylebox_override("background", StyleBoxEmpty.new())
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("8ab4f8")
	add_theme_stylebox_override("fill", fill)
	hide()

func set_progress(state: int, percent: int) -> void:
	var reported := Vector2i(state, percent)
	if _reported == reported: return
	_reported = reported
	visible = state != 0
	indeterminate = state != 0 and (state == 3 or percent < 0)
	value = clampi(percent, 0, 100)
	get_theme_stylebox("fill").bg_color = Color("ff8080") if state == 2 else Color("ffd078") if state == 4 else Color("8ab4f8")
