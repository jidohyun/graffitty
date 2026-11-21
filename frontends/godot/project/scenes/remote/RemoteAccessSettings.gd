extends AcceptDialog
## Passwords are registered locally; only the OPAQUE verifier is persisted.
const SecretInput := preload("res://scenes/SecretInput.gd")
var password: LineEdit = SecretInput.new()
var confirm: LineEdit = SecretInput.new()
const TEMPORARY := 0
const MANUAL_ONLY := 1
var password_mode := OptionButton.new()
var password_fields := VBoxContainer.new()
var temporary_fields := VBoxContainer.new()
var mode_help := Label.new()
var permanent_configured := false
var telegram := CheckBox.new()
var profile := LineEdit.new()
var bot_token: LineEdit = SecretInput.new()
var chat_id := LineEdit.new()
var telegram_fields := VBoxContainer.new()
var telegram_status := Label.new()
var loaded_telegram_credential := ""
var saved_telegram_token := false
var status := Label.new()
var temporary_length := OptionButton.new()
var temporary: LineEdit = SecretInput.new()
var application: Node
var authentication: RefCounted
var path := preload("res://graffitty/paths.gd").stdpath("state").path_join("auth.json")


func _ready() -> void:
	if application.has_method("refresh_remote_access"):
		if await application.refresh_remote_access() == OK:
			path = application.remote_control.auth_path
	title = "Remote Access Settings"
	ok_button_text = "Save"
	dialog_hide_on_ok = false
	authentication = ClassDB.instantiate("RemoteAuth")
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(520, maxf(200, minf(600, get_tree().root.get_visible_rect().size.y - 120)))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	fields.add_child(status)
	var mode_label := Label.new()
	mode_label.text = "Password access"
	fields.add_child(mode_label)
	password_mode.add_item("Temporary password", TEMPORARY)
	password_mode.add_item("Manual password only", MANUAL_ONLY)
	fields.add_child(password_mode)
	mode_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fields.add_child(mode_help)
	fields.add_child(temporary_fields)
	fields.add_child(password_fields)
	password_mode.item_selected.connect(func(_index): _update_password_mode())
	var length_label := Label.new()
	length_label.text = "Temporary password length"
	temporary_fields.add_child(length_label)
	for length in [6, 8, 10]:
		temporary_length.add_item(tr("%d characters") % length, length)
	temporary_fields.add_child(temporary_length)
	temporary.editable = false
	temporary_fields.add_child(temporary)
	temporary.hide()
	if application.remote_access_enabled() and not application.remote_control.token.is_empty():
		temporary.text = application.remote_control.token
		temporary.show()
		var description := Label.new()
		description.text = "Temporary password (changes when sharing restarts)"
		temporary_fields.add_child(description)
		var actions := HBoxContainer.new()
		var copy := Button.new()
		copy.text = "Copy"
		copy.pressed.connect(func(): DisplayServer.clipboard_set(temporary.text))
		actions.add_child(copy)
		var regenerate := Button.new()
		regenerate.text = "Regenerate"
		regenerate.tooltip_text = "Replace the temporary password and disconnect remote clients"
		regenerate.pressed.connect(_regenerate_temporary)
		actions.add_child(regenerate)
		temporary_fields.add_child(actions)
	password.placeholder_text = "New password (leave blank to keep)"
	confirm.placeholder_text = "Confirm new password"
	password_fields.add_child(password)
	password_fields.add_child(confirm)
	telegram.text = "Require Telegram two-factor authentication (2FA)"
	fields.add_child(telegram)
	fields.add_child(telegram_fields)
	profile.text = "graffitty-2fa"
	bot_token.placeholder_text = "Bot token from @BotFather"
	chat_id.placeholder_text = "Numeric chat ID, e.g. 123456789"
	for field in [["Credential name", profile], ["Telegram bot token", bot_token], ["Destination chat ID", chat_id]]:
		var caption := Label.new()
		caption.text = field[0]
		telegram_fields.add_child(caption)
		telegram_fields.add_child(field[1])
	telegram_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	telegram_fields.add_child(telegram_status)
	telegram.toggled.connect(func(enabled):
		telegram_fields.visible = enabled
		if enabled: _load_telegram_settings()
	)
	profile.focus_exited.connect(_load_telegram_settings)
	var settings: Dictionary = JSON.parse_string(authentication.settings(path))
	if settings.has("error"):
		status.text = settings.error
		get_ok_button().disabled = true
	else:
		permanent_configured = bool(settings.permanent)
		password_mode.select(MANUAL_ONLY if permanent_configured else TEMPORARY)
		status.text = "Manual password configured" if permanent_configured else "Using a temporary password"
		temporary_length.select(temporary_length.get_item_index(int(settings.temporary_password_length)))
		telegram.set_pressed_no_signal(settings.get("telegram_credential") is String)
		if telegram.button_pressed:
			profile.text = settings.telegram_credential
		chat_id.text = str(settings.get("chat_id") if settings.get("chat_id") is String else "")
	_update_password_mode()
	telegram_fields.visible = telegram.button_pressed
	if telegram.button_pressed: _load_telegram_settings()
	Engine.get_main_loop().root.get_node("Localization").changed.connect(_refresh_language)
	confirmed.connect(_save)
	canceled.connect(queue_free)
	popup_centered.call_deferred()


func _update_password_mode() -> void:
	temporary.revealed = false
	var manual := password_mode.get_selected_id() == MANUAL_ONLY
	password_fields.visible = manual
	temporary_fields.visible = not manual
	password.placeholder_text = "New manual password (leave blank to keep)" if permanent_configured else "Set manual password (at least 8 characters)"
	mode_help.text = "Temporary passwords are disabled. Only your manual password will be accepted." if manual else "A new temporary password is generated when sharing restarts."
	if not manual and permanent_configured:
		mode_help.text = tr(mode_help.text) + " " + tr("Saving this mode removes your manual password.")


func _save() -> void:
	var manual := password_mode.get_selected_id() == MANUAL_ONLY
	if manual and not permanent_configured and password.text.is_empty():
		status.text = "Set a manual password before disabling temporary passwords"
		return
	if manual and password.text != confirm.text:
		status.text = "Passwords do not match"
		return
	if telegram.button_pressed and profile.text.strip_edges().is_empty():
		status.text = "Enter a credential name"
		return
	if telegram.button_pressed and (not bot_token.text.is_empty() or saved_telegram_token and not chat_id.text.is_empty()):
		var credentials: Dictionary = JSON.parse_string(authentication.save_telegram_credentials(profile.text.strip_edges(), bot_token.text.strip_edges(), chat_id.text.strip_edges()))
		if credentials.has("error"):
			status.text = credentials.error
			return
		bot_token.clear()
	var result: Dictionary = JSON.parse_string(authentication.save_settings(path, password.text if manual else "", not manual, profile.text.strip_edges() if telegram.button_pressed else "", chat_id.text.strip_edges() if telegram.button_pressed else "", temporary_length.get_selected_id()))
	if result.has("error"):
		status.text = result.error
		return
	password.clear()
	confirm.clear()
	if application.has_method("refresh_remote_access"):
		var error: Error = await application.remote_control.reload()
		if error != OK:
			status.text = application.remote_control.last_error
			return
	queue_free()


func _load_telegram_settings() -> void:
	if not telegram.button_pressed or profile.text.strip_edges().is_empty(): return
	if loaded_telegram_credential == profile.text.strip_edges(): return
	loaded_telegram_credential = profile.text.strip_edges()
	var saved: Dictionary = JSON.parse_string(authentication.telegram_settings(profile.text.strip_edges()))
	bot_token.clear()
	saved_telegram_token = bool(saved.get("saved", false))
	if saved_telegram_token: chat_id.text = str(saved.get("chat_id", ""))
	bot_token.placeholder_text = "Saved token (leave blank to keep)" if saved.get("saved", false) else "Bot token from @BotFather"
	telegram_status.text = str(saved.get("error", "Bot credentials saved" if saved.get("saved", false) else ""))
	telegram_status.visible = not telegram_status.text.is_empty()


func _regenerate_temporary() -> void:
	temporary.revealed = false
	var current: Dictionary = JSON.parse_string(authentication.settings(path))
	if current.has("error"):
		status.text = current.error
		return
	var current_profile: String = current.telegram_credential if current.get("telegram_credential") is String else ""
	var result: Dictionary = JSON.parse_string(authentication.save_settings(path, "", false, current_profile, str(current.get("chat_id") if current.get("chat_id") is String else ""), temporary_length.get_selected_id()))
	if result.has("error"):
		status.text = result.error
		return
	var err: Error = await application.remote_control.reload(true)
	temporary.text = application.remote_control.token if err == OK else ""
	status.text = "Temporary password regenerated" if err == OK else tr("Could not update remote access: %s") % error_string(err)

func _refresh_language() -> void:
	for index in temporary_length.item_count:
		temporary_length.set_item_text(index, tr("%d characters") % temporary_length.get_item_id(index))
	_update_password_mode()
