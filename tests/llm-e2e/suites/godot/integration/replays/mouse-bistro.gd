extends "mouse-controls.gd"

func play() -> void:
	if not await open_bistro():
		return
	await super.play()
