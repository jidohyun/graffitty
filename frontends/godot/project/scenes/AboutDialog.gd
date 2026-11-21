extends AcceptDialog
## One compact, scrollable build report for the manager and workspace.
##
## The report selects and scrolls like a terminal; copy the selection with
## Cmd/Ctrl+C or the context menu (Android: its own Copy toolbar).
var report := preload("res://scenes/SelectableText.gd").new()

func _init() -> void:
	title = "About Graffitty"
	exclusive = true
	# The Android scrollbar sits in the dialog margin, against its edge.
	report.bar_outside = true
	add_child(report)

func _ready() -> void:
	get_parent().get_viewport().size_changed.connect(func():
		if visible: present())

func present() -> void:
	report.text = preload("res://scenes/BuildInfo.gd").report()
	# Narrow, like a system About box: hashes wrap at any width, so a wide
	# dialog only adds empty space beside the short lines.
	var room := get_parent().get_viewport().get_visible_rect().size * .85
	report.custom_minimum_size = Vector2(320, 240).min((room - Vector2(40, 100)).max(Vector2(120, 80)))
	min_size = Vector2i.ZERO
	popup_centered_clamped(Vector2i(Vector2(344, 330).min(room)), .9)
