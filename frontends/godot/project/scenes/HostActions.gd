extends RefCounted
## The shared action dispatcher. Menus, direct shortcuts, `Prefix+…` sequences
## and the command line all run PascalCase actions from the Rust registry
## (crates/client-config) here; none keeps a separate implementation.
const Effects := preload("res://graffitty/effects.gd")

## Run while the focused pane is a terminal and no UI text field has focus.
const TERMINAL := {
	"Copy": "copy", "Paste": "paste", "Find": "search", "QuickSelect": "quick_select",
	"CopyMode": "copy_mode", "CopyLastOutput": "copy_last_output",
	"PreviousPrompt": "previous_prompt", "NextPrompt": "next_prompt",
	"ScrollPageUp": "scroll_page_up", "ScrollPageDown": "scroll_page_down",
	"ScrollTop": "scroll_top", "ScrollBottom": "scroll_bottom",
	# Key routing: the native action is followed by the entry's text.
	"SendText": "send_text:", "Ignore": "ignore",
}
## Actions that need a key binding's or menu entry's parameters; the command
## line does not list them.
const PARAMETERIZED := ["SendText", "Ignore", "SetEffectsProfile", "ToggleEffect", "OpenPanel"]
const FONT_SIZE := {"IncreaseFontSize": 1, "DecreaseFontSize": -1, "ResetFontSize": 0}
const NATIVE_FONT_SIZE := {"IncreaseFontSize": "increase_font_size", "DecreaseFontSize": "decrease_font_size", "ResetFontSize": "reset_font_size"}
## Held keys repeat these actions.
const REPEATABLE := ["IncreaseFontSize", "DecreaseFontSize", "ScrollPageUp", "ScrollPageDown", "PreviousPrompt", "NextPrompt"]
const CHECKPOINTS := ["SaveCheckpoint", "SaveCheckpointAndQuit"]


static func names() -> PackedStringArray:
	return ClassDB.class_call_static("ClientConfig", "actions")


## Whether `action` can run in the host's current focus. A shortcut that is
## not applicable reaches the focused pane or control instead.
static func applicable(host: Node, action: String) -> bool:
	var view: bool = "workspace_view" in host and is_instance_valid(host.workspace_view)
	if TERMINAL.has(action):
		return (host.is_terminal_pane(host.pane_focus) and host.sessions.has(host.active_session_id)
			and not preload("res://scenes/WorkspacePrefix.gd").text_input_focused(host))
	if FONT_SIZE.has(action):
		return host.is_terminal_pane(host.pane_focus) or host.is_chromium_pane(host.pane_focus)
	match action:
		"NewWindow":
			return not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		"NewPaneLeft", "NewPaneRight", "NewPaneAbove", "NewPaneBelow", "ResizeToFitMain", "FitToMainArea", "Overview", "ToggleTiling", "RenamePane", "ClosePane":
			return view
		"FitToPane":
			return view and host.workspace_view.pane_rects.has(host.pane_focus)
		"SetEffectsProfile":
			return is_instance_valid(host.world) and host.world.get("fx_cfg") != null
		"SaveCheckpoint", "SaveCheckpointAndQuit":
			return not OS.has_feature("mobile")
	return true


## Run `action`; `params` carries menu parameters (profile, url, tag). Returns
## false when the action does not apply to the current focus.
static func run(host: Node, action: String, params: Dictionary = {}) -> bool:
	if not applicable(host, action):
		return false
	if action == "SendText":
		if str(params.get("text", "")).is_empty():
			return false
		host.terminal_menu_action("send_text:" + str(params.text))
		return true
	if action == "OpenPanel":
		var mod := str(params.get("name", ""))
		if mod.is_empty():
			push_error("OpenPanel needs a mod name")
			return false
		preload("res://scenes/mods/PanelWindow.gd").toggle(host, mod)
		return true
	if action == "SetEffectsProfile":
		var profile := str(params.get("profile", ""))
		if not host.effect_profiles.has(profile):
			push_error("Unknown effects profile: " + profile)
			return false
		host.set_effects_profile(profile)
		return true
	if action == "ToggleEffect":
		var effect := str(params.get("effect", ""))
		if effect not in Effects.NAMES:
			push_error("Unknown effect: " + effect)
			return false
		host.toggle_effect(effect)
		return true
	if TERMINAL.has(action):
		host.terminal_menu_action(TERMINAL[action])
		return true
	if FONT_SIZE.has(action):
		host.change_text_size(FONT_SIZE[action])
		return true
	if action.begins_with("SelectSession"):
		preload("res://scenes/session/LiveSessionMenu.gd").step(host, action.trim_prefix("SelectSession"))
		return true
	if action.begins_with("SelectTab"):
		host.select_numbered_tab(KEY_0 + int(action.trim_prefix("SelectTab")))
		return true
	if action in CHECKPOINTS:
		var entry := {"action": action, "tag": params.get("tag", "manual")}
		host.application.checkpoints.menu_action(host, entry)
		return true
	var focus := {"FocusLeft": "left", "FocusRight": "right", "FocusUp": "up", "FocusDown": "down"}
	if focus.has(action):
		host.navigator.focus_direction(focus[action])
		return true
	match action:
		"NewTab": host.create_session()
		"NewChromium":
			if params.has("profile") or params.has("url"):
				host.create_chromium_session(str(params.get("url", "")), -1, true, params.get("profile"))
			else:
				host.create_chromium_session()
		"NewWindow": host.create_native_window()
		"NextTab": host.select_next_workspace(1)
		"PreviousTab": host.select_next_workspace(-1)
		"ShowAllTabs": host.open_tab_menu()
		"NewPaneRight": host.workspace_view.split_window("h")
		"NewPaneLeft": host.workspace_view.split_window("h", "", true)
		"NewPaneBelow": host.workspace_view.split_window("v")
		"NewPaneAbove": host.workspace_view.split_window("v", "", true)
		"RenamePane": host.rename_pane(host.pane_focus)
		"ClosePane": host.close_focused_pane()
		"CloseWindow": host.request_close_window()
		"CloseTab": host.request_close_tab()
		"CloseSession": host.request_close_session()
		"NewSession": preload("res://scenes/session/LiveSessionMenu.gd").create_for(host)
		"NextAgent": host.application.agents.step(1)
		"PreviousAgent": host.application.agents.step(-1)
		"NextSession": preload("res://scenes/session/LiveSessionMenu.gd").step(host, "next")
		"PreviousSession": preload("res://scenes/session/LiveSessionMenu.gd").step(host, "previous")
		"LastSession": preload("res://scenes/session/LiveSessionMenu.gd").step(host, "last")
		"ResizeToFitMain": host.workspace_view.resize_to_fit_main()
		"FitToPane": host.workspace_view.toggle_fit_pane(host.pane_focus)
		"FitToMainArea": host.workspace_view.fit_to_main_area()
		"Overview": host.workspace_view.show_overview()
		"ToggleTiling": host.workspace_view.toggle_tiling()
		"ToggleFiletree": host.prefix_commands.filetree.toggle(host)
		"ToggleFiletreeFocus": host.prefix_commands.filetree.toggle(host, true)
		"SendPrefix": host.prefix_commands.send_prefix()
		"TogglePrefix": host.prefix_commands.toggle()
		"SendLiteral": host.navigator.send_literal()
		"SettleEffects": host.settle_effects(Effects.resolve({"include": ["typing"]}))
		"ReleaseEffectHolds": host.release_effect_holds()
		"PaneStatus": host.toggle_pane_status()
		"ResourceMonitor": preload("res://scenes/mods/PanelWindow.gd").toggle(host, "resource-monitor")
		"ToggleSidePanels": preload("res://scenes/ListDockSpace.gd").for_window(host.get_window()).toggle_panels()
		"StatusLine": preload("res://scenes/mods/PanelWindow.gd").toggle(host, "status-line")
		"Agents": preload("res://scenes/mods/PanelWindow.gd").toggle(host, "agents")
		"AllSessions": preload("res://scenes/session/SessionsDialog.gd").open(host)
		"Messages":
			if host.diagnostic_panel != null and is_instance_valid(host.diagnostic_panel.window): host.diagnostic_panel.dismiss_messages()
			else: host.show_messages()
		"Notifications": host.notification_overlay.toggle_history()
		"Info": host.show_info()
		_:
			push_error("Unknown action: " + action)
			return false
	return true


## "FocusLeft" → "Focus Left", for command-line titles of unmenued actions.
static func title(action: String) -> String:
	var words := ""
	for index in action.length():
		var character := action[index]
		if index > 0 and character == character.to_upper() and character != character.to_lower():
			words += " "
		elif index > 0 and character.is_valid_int() and not action[index - 1].is_valid_int():
			words += " "
		words += character
	return words
