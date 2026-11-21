extends RefCounted
## Session ownership boundary. The UI calls these operations for every backend.
var is_remote := false


func authoritative() -> bool:
	return false


func configure_terminal(terminal: Node) -> void:
	terminal.remote_mode = true
	terminal.web_only_hyperlinks = true


func create_tab(_host: Node) -> void:
	push_error("A shared session connection is required to create a terminal")


func create_pane(_host: Node, _beside: String, _axis: String, _before := false) -> void:
	push_error("A shared session connection is required to split a pane")


func close_pane(_host: Node, _id: int) -> void:
	push_error("A shared session connection is required to close a terminal")


## Tabs with the same scope belong to one session and share a tab strip. Only a
## window that shows several servers' sessions at once has more than one scope.
func session_scope(_tab: int) -> int:
	return 0


## The affected session and server when closing these panes ends a session.
func session_close_impact(_ids: Array) -> Dictionary:
	return {}


func close_tab(_host: Node, _id: int) -> void:
	push_error("A shared session connection is required to close a workspace")


func content_rect(_host: Node, fallback: Rect2) -> Rect2:
	return fallback


func sync_window_area(_host: Node) -> void:
	pass


func note_activity(_host: Node) -> void:
	pass


## Arrival geometry must reflect the acknowledged layout and its terminal grid.
func transition_layout_ready(_host: Node) -> bool:
	return true


func resize_pane(_host: Node, _key: String, _rect: Rect2) -> void:
	pass


func sync_pane_grid(_host: Node, _key: String) -> void:
	pass


func move_pane(_host: Node, _key: String, _point: Vector2) -> void:
	pass


func set_tiling(_host: Node, _enabled: bool) -> void:
	pass


func resize_tiles(_host: Node) -> void:
	pass


func create_chromium_remote(_host: Node, _owner: int, _url: String, _reveal: bool, _profile: Variant) -> Dictionary:
	return {"error": {"message": "A shared session connection is required to open a chromium"}}


func set_default_tiling(host: Node, enabled: bool) -> void:
	host.application.tiling_default = enabled
