"""Run a Godot SceneTree probe in a packaged app.

- With --script support, the probe initializer boots the main scene.
- Otherwise, use a temporary autoload to join the existing SceneTree
  and defer probe(). See macos_bundle_replacement_e2e.py.

Probe scripts live outside the app bundle and user configuration.
"""
from pathlib import Path
import textwrap

_BOOT = '''extends SceneTree
## Packaged-app probe: boots the application's main scene, then runs probe().
var host: Node


func _initialize() -> void:
	_boot.call_deferred()


func _boot() -> void:
	root.add_child(load(ProjectSettings.get_setting("application/run/main_scene")).instantiate())
	await probe()


func application() -> Node:
	return root.get_node("TerminalApplication")


## The first window's host once it has a live shell, or null after `seconds`.
func first_host(seconds := 30.0) -> Node:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		var app := application()
		if not app.hosts.is_empty() and app.hosts[0].active_terminal() != null and app.hosts[0].active_terminal().get_shell_pid() > 0:
			return app.hosts[0]
		await process_frame
	return null


func probe() -> void:
'''


def write_probe(path: Path, body: str) -> Path:
    """Write a probe whose ``probe()`` coroutine is ``body`` (GDScript, any indent)."""
    lines = textwrap.dedent(body).strip("\n").splitlines() or ["pass"]
    path.write_text(_BOOT + "".join("\t" + line + "\n" for line in lines), encoding="utf-8")
    return path
