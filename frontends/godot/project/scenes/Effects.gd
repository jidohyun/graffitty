extends RefCounted
const SessionSwitchSettings := preload("res://scenes/SessionSwitchSettings.gd")
## Load effect settings from a Godot ConfigFile.
##
## - `[state.<name>]` sets values that change with behavior, such as zoom,
##   ripple amplitude, and particle type. Presets often define `idle` and
##   `typing`. Custom names work too.
## - `[scene.*]` sets values shared by every state, such as ripple
##   wavelength, particle count, and tilt-light colors.
## - `[behavior]` controls when and how fast states change.
##
##     [scene.sheet]
##     ripple_wavelength = 0.22
##     corner_radius = 20
##
##     [behavior]
##     enter_duration = 0.5
##     idle_after = 1.2
##     leave_duration = 1.5
##
##     [state.idle]
##     camera.zoom = 1.0
##
##     [state.typing]
##     camera.zoom = 2.0
##     sheet.ripple = 9.0
##     typing.particles = "sparks"
##
## Compatible presets keep their option names and defaults. For settings
## such as depth-of-field blur and particle amount, the loader also reads
## the source name when Godot uses a different property name.


class TypingSettings extends RefCounted:
	var pane_zoom: float = 1.1
	var particles_amount: int = 6
	var particles_scale: float = 1.0
	var splash_scale: float = 0.0
	var splash_speed: float = 600.0
	var splash_life: float = 0.7


	func load_from(raw: Dictionary) -> TypingSettings:
		pane_zoom = clampf(_float(raw, "pane_zoom", pane_zoom), 1.0, 2.0)
		particles_amount = maxi(_int(raw, "particles_amount", particles_amount), 1)
		particles_scale = maxf(_float(raw, "particles_scale", particles_scale), 0.01)
		splash_scale = maxf(_float(raw, "splash_scale", splash_scale), 0.0)
		splash_speed = maxf(_float(raw, "splash_speed", splash_speed), 0.0)
		splash_life = maxf(_float(raw, "splash_life", splash_life), 0.01)
		return self


	func _int(raw: Dictionary, key: String, fallback: int) -> int:
		var value = raw.get(key, fallback)
		return int(value) if value is int or value is float else fallback


	func _float(raw: Dictionary, key: String, fallback: float) -> float:
		var value = raw.get(key, fallback)
		return float(value) if value is int or value is float else fallback


	func _bool(raw: Dictionary, key: String, fallback: bool) -> bool:
		var value = raw.get(key, fallback)
		return value if value is bool else fallback


class CursorTrailSettings extends RefCounted:
	var style := "smear"
	var options: Dictionary = {}
	var delay: int = 0
	var decay := Vector2(0.1, 0.4)
	var start_threshold := Vector2(2, 2)
	## Smear tint; transparent follows the cursor color.
	var color := Color.TRANSPARENT


	func load_from(raw: Dictionary) -> CursorTrailSettings:
		style = str(raw.get("style", "smear"))
		delay = maxi(int(raw.delay), 0)
		decay = _pair(raw.decay, decay)
		start_threshold = _pair(raw.start_threshold, start_threshold)
		return self


	func _pair(value: Variant, fallback: Vector2) -> Vector2:
		if value is Vector2:
			return value
		if value is float or value is int:
			return Vector2.ONE * float(value)
		if value is String:
			var words := String(value).split(" ", false)
			if words.size() == 1 and words[0].is_valid_float():
				return Vector2.ONE * words[0].to_float()
			if words.size() == 2 and words[0].is_valid_float() and words[1].is_valid_float():
				return Vector2(words[0].to_float(), words[1].to_float())
		return fallback


const SCENE_DEFAULTS := {
	"sheet": {
		"typing_shape": "flat",
		"curvature_deg": 24.0,
		"ripple_wavelength": 0.35,
		"ripple_speed": 2.5,
		"ripple_falloff": 0.3,
		"edge_margin": 0.0,
		"corner_radius": 0.0,
		"edge_blur": 0.0,
		"edge_shadow": 0.0,
		"edge_shadow_width": 48.0,
		"content_gloss": 0.0,
	},
	"typing": {
		"pane_zoom": 1.1,
		"particles_amount": 6,
		"particles_scale": 1.0,
		"splash_scale": 0.0,
		"splash_speed": 600.0,
		"splash_life": 0.7,
	},
	"camera": {
		## CameraAttributesPractical units: 1.0 is a 64 px blur radius at infinity.
		"dof_blur_amount": 0.125,
		"dof_blur_tint": "#9db2d6",
		"dof_blur_tint_strength": 1.0,
		"decay": 0.8,
		"overscroll": 0.5,
		"left_preserving_cursor_follow_threshold": 0.5,
		"top_preserving_cursor_follow_threshold": 0.5,
		"zoom_sensitivity": 0.15,
		"zoom_mode": "adaptive",
		"adaptive_zoom_in_seconds": 10.0,
		"adaptive_zoom_out_seconds": 1.5,
		## Panes framed together with the focused one while typing, by relation.
		## false: never; true: whenever they fit; a number 0–1: only when the gap
		## between them wastes at most that share of the frame.
		"adaptive_group": {"main_view": true, "filetree": 0.25, "chromium": false, "spawned": false, "graph": false},
		"graphics_plane_tilt_scale": 1.0,
		"graphics_plane_lift": 0.0,
	},
	"lighting": {
		"strength": 0.5,
		"minimum": 0.45,
		"maximum": 1.15,
		"color": "#fff0dc",
	},
	"cursor_trail.blaze": {"duration": 0.5, "color": "#ffb929", "accent_color": "#ff0000"},
	"cursor_trail.lightning": {"duration": 0.14, "color": "#ffb929", "glow_color": "#bd0000", "jaggedness": 0.085, "core_width": 1.15, "glow_width": 5.5},
	"cursor_trail.smear": {"color": "none"},
	"cursor_trail": { "style": "lightning", "delay": 3, "decay": "0.1 0.4", "start_threshold": "2" },
	"tab_switch": { "effect": "push_pull" },
	"session_switch": { "effect": "fly_away_and_in", "max_blocks": 0, "dust_particles": 32768,
		"fly_ratio_sparse": SessionSwitchSettings.SPARSE_RATIO, "fly_ratio_dense": SessionSwitchSettings.DENSE_RATIO,
		"fly_dense_count": SessionSwitchSettings.DENSE_COUNT },
	"world": { "mode": "3d", "wallpaper": "", "color": "#0d0e12" },
}

## One state's frame; anything a state omits falls back to this.
const FRAME_DEFAULTS := {
	"camera.zoom": 1.0,
	"camera.drift_px": 0.0,
	"camera.drift_speed": 2.5,
	"camera.shake_px": 0.0,
	"camera.shake_seconds": 0.18,
	"camera.tilt_limit_deg": 0.0,
	"sheet.ripple": 0.0,
	"sheet.curvature_deg": 0.0,
	"typing.particles": "none",
}

const BEHAVIOR_DEFAULTS := {
	"enter_duration": 0.5,
	"idle_after": 1.2,
	"leave_duration": 1.5,
	"rest_state": "idle",
	"active_state": "typing",
}

var scene: Dictionary = { }
var behavior: Dictionary = { }
var states: Dictionary = { }
var warnings: Array[String] = []



func _init() -> void:
	scene = _copy(SCENE_DEFAULTS)
	behavior = BEHAVIOR_DEFAULTS.duplicate()
	states = { "idle": { }, "typing": { } }


func load_config(path: String) -> bool:
	## Later files merge onto earlier ones, the way kitty merges configs and
	## repeated effects.configure() calls accumulate.
	# A bare relative path is neither res:// nor absolute, and Godot resolves
	# neither — silently loading nothing. Treat it as project-relative.
	var resolved := path
	if not path.is_absolute_path():
		resolved = "res://" + path
	var cf := ConfigFile.new()
	var error := cf.load(preload("res://config/UserConfig.gd").expand_home(resolved))
	if error != OK:
		push_warning("Cannot read effects preset %s (error %d)" % [resolved, error])
		return false
	for section in cf.get_sections():
		if (
			section.begins_with("terminal.")
			or section in ["", "terminal", "world", "menu", "window", "power"]
		):
			continue # ConfigFile reports leading comments as a nameless section
		for key in cf.get_section_keys(section):
			set_option(section, key, cf.get_value(section, key))
	return true


func set_option(section: String, key: String, value) -> void:
	## One `[section] key = value`. Also the path a command-line override takes,
	## so both routes validate identically.
	if section.begins_with("state.") and key in ["sheet.shape", "sheet.typing_shape"]:
		if section == "state." + str(behavior.active_state):
			set_option("scene.sheet", "typing_shape", value)
		return
	if section == "scene.camera" and key == "zoom_mode" and str(value) not in ["typing", "adaptive"]:
		_warn("camera.zoom_mode must be typing or adaptive")
		return
	if section == "scene.camera" and key in ["adaptive_zoom_in_seconds", "adaptive_zoom_out_seconds"]:
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < .001 or float(value) > 60.0:
			_warn("camera.%s must be a finite number between 0.001 and 60 seconds" % key)
			return
	if section == "scene.camera" and key == "adaptive_group":
		if not value is Dictionary:
			_warn("camera.adaptive_group must be a dictionary like { \"filetree\": 0.25 }")
			return
		var merged: Dictionary = scene.camera.adaptive_group.duplicate()
		for relation in value:
			if not merged.has(relation):
				_warn("camera.adaptive_group: unknown relation '%s' (main_view, filetree, chromium, spawned, graph)" % str(relation))
				return
			var limit = value[relation]
			if relation == "main_view" and not limit is bool:
				_warn("camera.adaptive_group.main_view must be true or false")
				return
			if limit == null or limit is bool:
				merged[relation] = bool(limit)
			elif (limit is int or limit is float) and is_finite(float(limit)) and float(limit) >= 0.0 and float(limit) <= 1.0:
				merged[relation] = float(limit)
			else:
				_warn("camera.adaptive_group.%s must be true, false or a gap share from 0 to 1" % str(relation))
				return
		value = merged
	if section == "scene.sheet" and key == "typing_shape" and str(value) not in ["flat", "saddle"]:
		_warn("sheet.typing_shape must be flat or saddle")
		return
	if section == "scene.tab_switch" and key == "effect" and str(value) not in ["none", "push_pull"]:
		_warn("tab_switch.effect must be none or push_pull")
		return
	if section == "scene.session_switch" and key == "effect" and str(value) not in ["none", "fly_away_and_in", "fly_away"]:
		_warn("session_switch.effect must be none, fly_away_and_in or fly_away")
		return
	if section == "scene.session_switch" and key == "dust_particles":
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or int(value) < 1 or int(value) > 131072:
			_warn("session_switch.dust_particles must be an integer from 1 to 131072")
			return
	if section == "scene.session_switch" and key == "max_blocks":
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or int(value) < 0 or int(value) > 4096:
			_warn("session_switch.max_blocks must be an integer from 0 to 4096 (0 keeps fine scatter)")
			return
	if section == "scene.session_switch" and key in ["fly_ratio_sparse", "fly_ratio_dense"]:
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > 1.0:
			_warn("session_switch.%s must be a ratio from 0 to 1" % key)
			return
	if section == "scene.session_switch" and key == "fly_dense_count":
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 1 or float(value) > 1000000:
			_warn("session_switch.fly_dense_count must be an integer from 1 to 1000000")
			return
	if section.begins_with("state."):
		var name := section.substr(6)
		if not states.has(name):
			states[name] = { } # states are open-ended by design
		if not FRAME_DEFAULTS.has(key):
			_warn("unknown state key '%s' in [%s]" % [key, section])
			return
		states[name][key] = value
	elif section == "behavior":
		if not behavior.has(key):
			_warn("unknown key '%s' in [behavior]" % key)
			return
		behavior[key] = value
	elif section.begins_with("scene."):
		var group := section.substr(6)
		if not scene.has(group):
			_warn("unknown section [%s]" % section)
			return
		if not scene[group].has(key):
			_warn("unknown key '%s' in [%s]" % [key, section])
			return
		scene[group][key] = value
	else:
		_warn("unknown section [%s]" % section)


func frame(state: String) -> Dictionary:
	## A state's fully resolved frame.
	var out := FRAME_DEFAULTS.duplicate()
	if states.has(state):
		for k in states[state]:
			out[k] = states[state][k]
	elif not states.is_empty():
		_warn("no such state '%s'" % state)
	# A single mode selector prevents authored fixed zoom and adaptive fit stacking.
	if scene.camera.zoom_mode == "adaptive": out["camera.zoom"] = 1.0
	out["sheet.shape"] = scene.sheet.typing_shape if state == str(behavior.active_state) else "flat"
	if out["sheet.shape"] == "flat":
		out["sheet.curvature_deg"] = 0.0
	elif not states.get(state, { }).has("sheet.curvature_deg"):
		out["sheet.curvature_deg"] = float(scene.sheet.curvature_deg)
	return out


func cursor_trail_settings() -> CursorTrailSettings:
	var result := CursorTrailSettings.new().load_from(scene.cursor_trail)
	if result.style not in ["smear", "blaze", "lightning"]: result.style = "smear"
	if result.style == "smear":
		# Smear's only option is its tint, which the trail takes separately.
		var tint := str(scene.get("cursor_trail.smear", {}).get("color", "none"))
		result.color = Color.TRANSPARENT if tint in ["", "none"] else Color(tint)
	else:
		result.options = scene.get("cursor_trail." + result.style, {}).duplicate(true)
	return result


func typing_settings() -> TypingSettings:
	return TypingSettings.new().load_from(scene["typing"])


func blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	## Numbers ease; names and flags switch at the halfway point, because
	## 'sparks' has no midpoint with 'flames'.
	var out := { }
	var k := clampf(t, 0.0, 1.0)
	for key in a:
		var av = a[key]
		var bv = b.get(key, av)
		if key == "sheet.shape":
			# Keep the shape while its numeric curvature eases all the way to zero.
			out[key] = "saddle" if (av == "saddle" and k < 1.0) or (bv == "saddle" and k > 0.0) else "flat"
		elif (av is float or av is int) and (bv is float or bv is int):
			out[key] = lerpf(float(av), float(bv), k)
		else:
			out[key] = bv if k >= 0.5 else av
	return out


func curvature_deg(f: Dictionary) -> float:
	## Only 'saddle' has curvature; 'flat' ignores it.
	return float(f["sheet.curvature_deg"]) if String(f["sheet.shape"]) == "saddle" else 0.0


func describe() -> String:
	return "states=%s rest=%s active=%s enter=%.2f idle_after=%.2f leave=%.2f" % [
		states.keys(),
		behavior["rest_state"],
		behavior["active_state"],
		behavior["enter_duration"],
		behavior["idle_after"],
		behavior["leave_duration"],
	]


func _copy(d: Dictionary) -> Dictionary:
	var out := { }
	for k in d:
		out[k] = _copy(d[k]) if d[k] is Dictionary else d[k]
	return out


func _warn(msg: String) -> void:
	# Collected as well as pushed: a typo in a preset is otherwise invisible
	# until someone wonders why nothing changed.
	warnings.append(msg)
	push_warning("effects: " + msg)
