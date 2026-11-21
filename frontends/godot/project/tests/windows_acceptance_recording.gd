extends Node
## Capture the actual private frontend throughout lifecycle transitions.
var directory := ""
var elapsed := 0.0
var times: Array = []
func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed<.1:return
	elapsed=0
	RenderingServer.force_draw(false)
	var pixels:=get_window().get_texture().get_image()
	if pixels==null or pixels.is_empty():return
	pixels.save_jpg(directory.path_join("frame-%06d.jpg"%times.size()),.8)
	times.append(Time.get_ticks_msec())
	FileAccess.open(directory.path_join("frames.json"),FileAccess.WRITE).store_string(JSON.stringify(times))
