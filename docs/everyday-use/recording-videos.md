# Record a video

You can record a video of the real Graffitty app, for example a demo of your
CLI tool. Graffitty's own demo and effect videos are made this way.

## How it works

- **Frame-exact:** Godot's Movie Maker writes every frame at a fixed rate,
  so the video is smooth even on a slow machine. It has no audio.
- **Scripted:** a short Godot script types into the terminal. Its waits use
  the video's clock, so every take is the same.
- **Private:** the recording uses its own config folder, so it starts its own
  session server and never shows your real sessions.
- **Same shell everywhere (optional):** the terminal's shell can run in a
  Docker or Podman container. Graffitty itself stays on your machine.

## Simple setup

1. Make a folder for the recording, for example `demo/`, with the two files
   below.
2. Record (see [Record](#record)).

### `demo/record.gd`: what happens in the video

```gdscript
extends Node

var host: Node


func _ready() -> void:
	run()


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func type(text: String) -> void:
	for character in text:
		await host.agent_api.dispatch(host.active_session_id, "terminal.type", {"text": character})
		await wait(0.06)


func press(key: String) -> void:
	await host.agent_api.dispatch(host.active_session_id, "terminal.press", {"key": key})


func run() -> void:
	var app := get_tree().current_scene
	while app.host == null:
		await get_tree().process_frame
	host = app.host

	await wait(1.0)
	await type("mytool --help")
	await press("Enter")
	await wait(3.0)
	get_tree().quit()
```

Change the lines after `host = app.host` to script your own demo.

### `demo/config/graffitty/server.toml`: the shell and font

=== "macOS / Linux"

    ```toml
    [terminal]
    shell = ["/bin/zsh"]

    [terminal.font]
    size = 24
    ```

=== "Windows"

    ```toml
    [terminal]
    shell = ["pwsh.exe", "-NoLogo"]

    [terminal.font]
    size = 24
    ```

### Record

Run this from the `demo/` folder. Use full paths for the video and the
script. The video is 1600×1000 at 60 FPS.

=== "macOS"

    ```sh
    XDG_CONFIG_HOME="$PWD/config" XDG_DATA_HOME="$PWD/data" XDG_STATE_HOME="$PWD/state" \
      /Applications/Graffitty.app/Contents/MacOS/GraffittyRuntime \
      --write-movie "$PWD/demo.mp4" --fixed-fps 60 -- --record-script="$PWD/record.gd"
    ```

=== "Linux"

    ```sh
    XDG_CONFIG_HOME="$PWD/config" XDG_DATA_HOME="$PWD/data" XDG_STATE_HOME="$PWD/state" \
      ~/.local/share/graffitty/installs/current/gft-gui \
      --write-movie "$PWD/demo.mp4" --fixed-fps 60 -- --record-script="$PWD/record.gd"
    ```

=== "Windows"

    ```powershell
    $env:XDG_CONFIG_HOME = "$PWD\config"; $env:XDG_DATA_HOME = "$PWD\data"; $env:XDG_STATE_HOME = "$PWD\state"
    & "$env:LOCALAPPDATA\Programs\Graffitty\Graffitty.exe" `
      --write-movie "$PWD\demo.mp4" --fixed-fps 60 -- --record-script="$PWD\record.gd"
    ```

A window opens and plays the script, slower than real time, then closes when
the script calls `quit()`. `--record-script` only works together with
`--write-movie`.

The file extension picks the format:

| Extension | Result | Needs |
| --- | --- | --- |
| `.mp4` | Small AV1 video | FFmpeg with `libsvtav1` on `PATH` |
| `.avi` | Large MJPEG video | Nothing |
| `.png` | One image per frame | Nothing |

## Show a mouse pointer

The script can also move a visible pointer and click, like Graffitty's own
demo. Add these parts to `record.gd`:

1. At the top, after `var host: Node`:

    ```gdscript
    const DEVICE := 0xC0DE   # marks the script's own mouse events
    var pointer := Pointer.new()
    ```

2. In `_ready()`, before `run()`:

    ```gdscript
    	var layer := CanvasLayer.new()
    	layer.layer = 128   # draws above the app
    	layer.add_child(pointer)
    	add_child(layer)
    ```

3. At the end of the file:

    ```gdscript
    func move_to(target: Vector2, seconds := 0.6) -> void:
    	var start := pointer.at
    	var elapsed := 0.0
    	while elapsed < seconds:
    		elapsed += get_process_delta_time()
    		_send_motion(start.lerp(target, smoothstep(0.0, 1.0, elapsed / seconds)))
    		await get_tree().process_frame
    	_send_motion(target)


    func click(button := MOUSE_BUTTON_LEFT) -> void:
    	for down in [true, false]:
    		var event := InputEventMouseButton.new()
    		event.device = DEVICE
    		event.button_index = button
    		event.pressed = down
    		event.position = pointer.at
    		event.global_position = pointer.at
    		get_tree().root.push_input(event, true)
    		pointer.down = down
    		await wait(0.12)
    	pointer.ripple()


    func _send_motion(at: Vector2) -> void:
    	var event := InputEventMouseMotion.new()
    	event.device = DEVICE
    	event.position = at
    	event.global_position = at
    	event.relative = at - pointer.at
    	get_tree().root.push_input(event, true)
    	pointer.at = at


    # The visible pointer: an arrow, and a ring that spreads out after a click.
    class Pointer extends Control:
    	var at := Vector2(800, 500)
    	var down := false
    	var ring := 1.0

    	func _ready() -> void:
    		mouse_filter = MOUSE_FILTER_IGNORE

    	func ripple() -> void:
    		ring = 0.0

    	func _process(delta: float) -> void:
    		ring = minf(ring + delta / 0.5, 1.0)
    		queue_redraw()

    	func _draw() -> void:
    		if ring < 1.0:
    			draw_arc(at, lerpf(10, 34, ring), 0, TAU, 40, Color(0.35, 0.7, 1, 1 - ring), 3, true)
    		if down:
    			draw_circle(at, 16, Color(0.35, 0.7, 1, 0.35))
    		var arrow := PackedVector2Array([Vector2(0, 0), Vector2(0, 26), Vector2(7, 20),
    			Vector2(12, 31), Vector2(17, 29), Vector2(12, 18), Vector2(20, 18)])
    		for i in arrow.size():
    			arrow[i] = at + arrow[i] * 1.2
    		draw_colored_polygon(arrow, Color.WHITE)
    		draw_polyline(arrow + PackedVector2Array([arrow[0]]), Color.BLACK, 2, true)
    ```

Then use it in `run()`. Positions are window pixels in the 1600×1000 video:

```gdscript
	await move_to(Vector2(400, 300))
	await click()
```

The clicks reach the app like real ones. Don't type or move your own mouse
over the window while it records; that input reaches the app too.

## Optional: run the shell in a container

Only the shell moves into the container. Start one container, then make it
the terminal's shell in `server.toml`:

```sh
docker run -d --name demo-shell <image> sleep infinity   # or: podman run …
```

```toml
[terminal]
shell = ["docker", "exec", "-it", "demo-shell", "zsh"]    # or: "podman"
```

The image needs the shell and the tools your demo shows. Remove the container
with `docker rm -f demo-shell` when you are done.

## Example: Graffitty's own recordings

The [Graffitty repository](https://github.com/graffitty/graffitty/tree/main/videos)
uses this approach for its videos. Key files:

| File | What it shows |
| --- | --- |
| `videos/effects/recording/record.py` | Private config folders, `server.toml`, the container shell and the Movie Maker command |
| `videos/effects/recording/RecordEffects.gd` | Scripted typing and keys for each effect, on fixed frames |
| `videos/effects/recording/neutral.toml` | A neutral client config, so personal settings stay out of takes |
| `videos/shared/Containerfile` | The container image: zsh, a demo project and terminfo |
| `videos/main-demo/recording/tiling/` | A longer workspace demo with several panes |
