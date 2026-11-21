extends "res://tests/unit/test_case.gd"
const Icons := preload("res://scenes/PaneIcons.gd")


func test_compressed_import_becomes_black_menu_silhouette() -> void:
	# Exports pack the VRAM-compressed import instead of the SVG source.
	var imported := load("res://scenes/icons/folder-tree.svg") as Texture2D
	var source := imported.get_image()
	expect(source.is_compressed(), "Fixture is the compressed import of a white icon")
	var silhouette := Icons.menu_silhouette(imported)
	var image := silhouette.get_image() if silhouette != null else null
	if not expect(image != null and image.get_size() == source.get_size(), "Silhouette keeps the icon size"): return
	var original := source.duplicate() as Image
	original.decompress()
	var rgb := 0.0
	var alpha := 0.0
	var opaque := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			rgb = maxf(rgb, maxf(pixel.r, maxf(pixel.g, pixel.b)))
			alpha = maxf(alpha, absf(pixel.a - original.get_pixel(x, y).a))
			opaque += int(pixel.a > 0.5)
	expect(rgb == 0.0 and opaque > 0, "Native macOS menus receive black artwork")
	expect(alpha == 0.0, "Recoloring keeps the icon's alpha")
	expect(imported.get_image().is_compressed(), "The shared import is not modified")
	expect(Icons.menu_silhouette(imported) == silhouette, "Panes share one silhouette per icon")


func test_export_fallback_matches_development_icon_sizes() -> void:
	var chromium := Icons._imported("res://assets/icons/chromium.svg", 24.0 / 512.0)
	expect(chromium.get_size() == Icons.chromium().get_size() and chromium.get_size() == Vector2(24, 24), "The 512 px Chromium import becomes a 24 px icon")
	expect(not chromium.get_image().is_compressed(), "Scaled imports are plain images for native menus")
	expect(chromium.get_image().get_size() == Vector2i(48, 48), "Shrunk imports keep 2x pixels for HiDPI screens")
	var monitor := Icons._imported("res://assets/icons/stats.svg", 28.0 / 24.0)
	expect(monitor.get_size() == Icons.monitor().get_size(), "Imports apply the DPITexture scale")
	expect(monitor.get_image().get_size() == Vector2i(24, 24), "Grown imports are not resampled")
	var filetree := Icons._imported("res://scenes/icons/folder-tree.svg", 1.0)
	expect(filetree == load("res://scenes/icons/folder-tree.svg"), "Unscaled icons keep their import")


func test_menu_icon_follows_the_menu_renderer() -> void:
	var menu := PopupMenu.new()
	var icon := Icons.filetree()
	expect(Icons.menu_icon(menu, icon) == icon, "Godot-drawn menus keep white artwork on the dark theme")
	# Headless runs have no native popup menus.
	menu.prefer_native_menu = true
	if menu.is_native_menu():
		var native := Icons.menu_icon(menu, icon)
		if OS.get_name() == "Windows":
			expect(native == null, "Windows draws menu bitmaps opaque, so its native menus omit icons")
		else:
			expect(native == Icons.menu_silhouette(icon), "macOS native menus use black artwork")
	menu.free()
