extends PopupMenu
## Links come from Terminal's validated hyperlink hit test, which also decides
## whether this client may open them and whether they are web links.
signal open_in_browser_requested(uri: String)
signal show_in_chromium_requested(uri: String)
const Icons := preload("res://scenes/PaneIcons.gd")

enum Action { BROWSER, CHROMIUM, COPY }
var target := ""


func _ready() -> void:
	var desktop := OS.get_name() in ["macOS", "Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]
	prefer_native_menu = desktop
	force_native = desktop and DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS)
	add_item("Open in Browser", Action.BROWSER)
	add_icon_item(Icons.menu_icon(self, Icons.chromium()), "Show in Graffitty Chromium", Action.CHROMIUM)
	add_separator()
	add_item("Copy Link Address", Action.COPY)
	id_pressed.connect(_choose)


func display(uri: String, openable: bool, web: bool, screen: Vector2) -> void:
	preload("res://scenes/PopupChrome.gd").close(self)
	offer(uri, openable, web)
	reset_size()
	var at := screen
	if is_embedded():
		var viewport := get_parent().get_viewport()
		at = viewport.get_screen_transform().affine_inverse() * (at - Vector2(viewport.get_window().position))
	position = Vector2i(at)
	preload("res://scenes/PopupChrome.gd").open(self)


## Every link can be copied. Non-web links (file://, mailto:, ssh:) open with
## the client's default handler when Terminal allows it; only web links reach Chromium.
func offer(uri: String, openable: bool, web: bool) -> void:
	target = uri
	var open := get_item_index(Action.BROWSER)
	set_item_text(open, "Open in Browser" if web else "Open")
	set_item_disabled(open, not openable)
	set_item_disabled(get_item_index(Action.CHROMIUM), not web)


func _choose(id: int) -> void:
	if target.is_empty(): return
	var uri := target
	target = ""
	hide()
	if is_item_disabled(get_item_index(id)): return
	match id:
		Action.BROWSER: open_in_browser_requested.emit(uri)
		Action.CHROMIUM: show_in_chromium_requested.emit(uri)
		Action.COPY: DisplayServer.clipboard_set(uri)
