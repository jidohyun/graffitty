extends RefCounted
## Menu windows are not hidden by hiding their workspace Control ancestor.
## Use the same dismissal path for Android Back and leaving the workspace.
const MobileMenu := preload("res://scenes/input/MobileMenu.gd")
const TouchMenu := preload("res://scenes/input/TouchMenu.gd")

static func dismiss(scope: Node) -> bool:
	var dismissed := false
	var popups := scope.find_children("*", "PopupMenu", true, false)
	popups.reverse()
	for popup in popups:
		if popup.visible:
			popup.hide()
			dismissed = true
	for popup in scope.find_children("*", "PopupPanel", true, false):
		if popup is TouchMenu and (popup.visible or popup.pending):
			popup.dismiss()
			dismissed = true
	for panel in scope.find_children("*", "PanelContainer", true, false):
		if panel is MobileMenu and panel.expanded:
			panel.set_expanded(false, false)
			dismissed = true
	return dismissed
