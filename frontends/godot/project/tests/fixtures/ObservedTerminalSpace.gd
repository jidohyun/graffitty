extends "res://scenes/TerminalSpace.gd"
## Count work at the real presentation boundaries, including attempted no-op syncs.
var header_updates := 0
var link_updates := 0
var raster_updates := 0
var invalidate_during_header_update := false

func _update_compact_headers(for_transition := false) -> void:
	header_updates += 1
	super._update_compact_headers(for_transition)
	if invalidate_during_header_update:
		invalidate_during_header_update = false
		host.world.workspace_projection_changed.emit()

func _sync_chromium_links() -> void:
	link_updates += 1
	super._sync_chromium_links()

func update_raster_region() -> void:
	raster_updates += 1
	super.update_raster_region()

func counters() -> Array:
	return [header_updates, link_updates, raster_updates]
