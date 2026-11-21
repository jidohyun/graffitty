extends Node
const Diagnostics := preload("res://graffitty/diagnostics.gd")
const RenderStats := preload("res://graffitty/render_stats.gd")
signal changed


func _init() -> void:
	Diagnostics.start()


func _process(_delta: float) -> void:
	if Diagnostics.collect():
		changed.emit()
	RenderStats.tick(get_tree())


func _exit_tree() -> void:
	if Diagnostics.logger != null:
		OS.remove_logger(Diagnostics.logger)
		Diagnostics.logger.file = null
