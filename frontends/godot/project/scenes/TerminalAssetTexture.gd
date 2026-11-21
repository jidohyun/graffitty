extends Texture2DRD
## The texture owns the imported resource through every canvas/effect reference.
## Release on the rendering thread only after the last resource reference dies.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and texture_rd_rid.is_valid():
		var owned := texture_rd_rid
		texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(_release.bind(owned))

static func _release(owned: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		rd.free_rid(owned)
