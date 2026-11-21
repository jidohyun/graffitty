extends RefCounted
## Opens popup menus under the pointer. Native popup windows (desktop) take
## screen pixels.
##
## Popups embedded in a viewport (always on Android) take that viewport's
## coordinates, which differ from pixels under Android's content scale: a raw
## touch position lands far outside the viewport and gets clamped into a
## corner.
##
## Godot converts embedded positions itself for native menus.


static func open(menu: Window) -> void:
	var embedder := embedder_of(menu)
	# get_mouse_position() is already in the embedder's coordinates: a
	# SubViewport's last pushed pointer, or for the Android window the touch
	# (DisplayServer reports Input's position there) mapped through its scale.
	menu.position = Vector2i(embedder.get_mouse_position()) if embedder != null else DisplayServer.mouse_get_position()
	if menu is PopupMenu: preload("res://scenes/PopupChrome.gd").open(menu)
	else: menu.popup()


## The viewport a window embeds in, as Godot picks it: the nearest ancestor
## viewport that embeds subwindows. Null means the window is native.
static func embedder_of(window: Window) -> Viewport:
	var parent := window.get_parent()
	var viewport := parent.get_viewport() if parent != null else null
	while viewport != null:
		if viewport.gui_embed_subwindows:
			return viewport
		parent = viewport.get_parent()
		viewport = parent.get_viewport() if parent != null else null
	return null
