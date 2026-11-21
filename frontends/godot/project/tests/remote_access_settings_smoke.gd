extends SceneTree
var failures := 0
var path := ""
class Application extends Node:
	func remote_access_enabled() -> bool: return false

func _initialize() -> void:
	path = OS.get_cache_dir().path_join("graffitty-password-mode-%d.json" % Time.get_ticks_usec())
	run.call_deferred()

func expect(ok: bool, message: String) -> void:
	print("[password modes] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures += 1

func editor(app: Node) -> Node:
	var settings := preload("res://scenes/remote/RemoteAccessSettings.gd").new()
	settings.application = app
	settings.path = path
	root.add_child(settings)
	return settings

func run() -> void:
	root.gui_embed_subwindows = true
	var app := Application.new()
	root.add_child(app)
	var settings := editor(app)
	await process_frame
	var eye: Button = settings.temporary.toggle
	expect(settings.temporary.secret and eye.icon == settings.SecretInput.show_icon() and eye.tooltip_text == "Show password", "Temporary password starts concealed")
	eye.pressed.emit()
	expect(not settings.temporary.secret and eye.icon == settings.SecretInput.hide_icon() and eye.tooltip_text == "Hide password", "The eye reveals the temporary password and swaps its icon")
	eye.pressed.emit()
	expect(settings.temporary.secret and eye.icon == settings.SecretInput.show_icon(), "The eye conceals it again")
	eye.pressed.emit()
	settings.hide()
	expect(settings.temporary.secret, "Closing the dialog conceals a revealed password")
	settings.show()
	settings.password_mode.select(settings.MANUAL_ONLY)
	settings._update_password_mode()
	expect(not settings.temporary_fields.visible and settings.password_fields.visible, "Manual-only mode hides temporary password controls")
	settings._save()
	expect(not FileAccess.file_exists(path), "Cannot disable temporary access without first setting a manual password")
	settings.password.text = "test-only manual password"
	settings.confirm.text = settings.password.text
	settings._save()
	await process_frame
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var configured: Dictionary = JSON.parse_string(auth.configure(path, ""))
	expect(configured.get("permanent", false) and configured.get("temporary_password", "missing").is_empty(), "Manual-only mode persists and generates no temporary password")
	settings = editor(app)
	await process_frame
	expect(settings.password_mode.get_selected_id() == settings.MANUAL_ONLY, "Reopening settings preserves manual-only mode")
	settings.password_mode.select(settings.TEMPORARY)
	settings._update_password_mode()
	expect(settings.temporary_fields.visible and not settings.password_fields.visible, "Temporary mode exposes its own controls")
	settings._save()
	await process_frame
	configured = JSON.parse_string(auth.configure(path, ""))
	expect(not configured.get("permanent", true) and configured.get("temporary_password", "").length() == 6, "Temporary mode explicitly removes the manual password and restores generated passwords")
	DirAccess.remove_absolute(path)
	quit(0 if failures == 0 else 1)
