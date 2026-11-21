extends "../../remote-control/replays/local-client.gd"

func android_client() -> bool:
	return true

func client_script() -> String:
	return "res://tests/android_ui_e2e.gd"

func client_needs_window() -> bool:
	return true
