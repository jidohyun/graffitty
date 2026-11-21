extends "res://tests/unit/test_case.gd"

const Profiles := preload("res://scenes/input/FloatingLayoutProfile.gd")
const Floating := preload("res://scenes/input/FloatingButtons.gd")
const SIZES := [Vector2i(1080, 2520), Vector2i(2520, 1080), Vector2i(1968, 2184), Vector2i(2184, 1968)]

func test_four_distinct_fold_and_orientation_profiles() -> void:
	var keys := {}
	for size in SIZES: keys[Profiles.key(size)] = true
	expect(keys.size() == 4, "Cover/inner and portrait/landscape each select a separate profile")
	expect(Profiles.path("user://buttons.conf", Vector2i.ZERO) == "user://buttons.conf", "Desktop retains its regular layout file")

func test_profiles_restore_anchors_and_cancel_cross_screen_drag() -> void:
	var base := OS.get_cache_dir().path_join("floating-profile-unit-%d-%d.conf" % [OS.get_process_id(), Time.get_ticks_usec()])
	var config := ConfigFile.new()
	config.set_value("layout", "reference_size", Vector2(800, 600))
	config.set_value("anchors", "keyboard", Vector2(.8, .9))
	config.save(base)
	var state := {"size": SIZES[0]}
	var floating := Floating.new()
	floating.preferences_path = base
	floating.display_size_provider = func(): return state.size
	floating.add("keyboard", Button.new(), Vector2.ONE)
	for index in range(SIZES.size()):
		state.size = SIZES[index]
		floating._sync_profile()
		expect(floating._gesture.is_empty(), "Rotation/folding cancels the previous profile's drag")
		expect(floating.entries.keyboard.anchor == Vector2(.8, .9), "New profiles seed from default, not another profile's edits")
		var anchor := Vector2(.1 * (index + 1), .15 * (index + 1))
		floating.entries.keyboard.anchor = anchor
		floating._save("keyboard", anchor)
		floating._gesture = {"id": "keyboard", "dragging": true}
	floating.free()
	# Recreate the controller: persisted state, not just in-memory caching.
	floating = Floating.new()
	floating.preferences_path = base
	floating.display_size_provider = func(): return state.size
	floating.add("keyboard", Button.new(), Vector2.ONE)
	for cycle in range(10):
		for index in range(SIZES.size()):
			state.size = SIZES[index]
			floating._sync_profile()
			expect(floating.entries.keyboard.anchor == Vector2(.1 * (index + 1), .15 * (index + 1)), "Each of four layouts restores independently")
			floating.set_bottom_inset(300)
			floating.set_bottom_inset(0)
			expect(not floating._sync_profile(), "IME does not change the orientation profile")
	floating.free()
	DirAccess.remove_absolute(base)
	for size in SIZES: DirAccess.remove_absolute(Profiles.path(base, size))
