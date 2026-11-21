extends "res://tests/client_scenarios/remote_client.gd"
## Adapted image/scrollback scenarios from headless_remote_client_e2e.gd.
func has_image(terminal: Node, id: int) -> bool:
	return terminal.image_placements().any(func(p): return int(p.image_id) == id)
func run() -> void:
	client = preload("res://scenes/remote_client.tscn").instantiate()
	client.settings = settings
	root.add_child(client)
	expect(await until(func(): return client.host != null and client.connection.connected, FIRST_CONNECTION_SECONDS), "Image client authenticates")
	if client.host == null: finish(); return
	target = client.host.active_session_id
	var terminal: Node = client.host.sessions[target].term
	expect(await until(func(): return has_image(terminal, 9001)), "First attachment restores image sent before connection")
	terminal.send_text("printf '\\033[2J\\033[H\\033_Ga=T,f=32,s=2,v=1,i=9002,p=1,c=4,r=2,q=2;/wAA/wD/AP8=\\033\\\\'\r")
	expect(await until(func(): return has_image(terminal, 9002)), "Live inline image reaches native Android renderer")
	terminal.send_text(
		r"""python3 -c 'import base64,tempfile; p=tempfile.mkstemp(prefix="tty-graphics-protocol-")[1]; open(p,"wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")); print("\x1b_Ga=T,t=t,f=100,i=9003,p=1,c=4,r=2,q=2;"+base64.b64encode(p.encode()).decode()+"\x1b\\",end="",flush=True)'""" + "\r")
	expect(await until(func(): return has_image(terminal, 9003)), "Server file image resolves without Android filesystem access")
	client.connection.disconnect_remote()
	var grid: Vector2i = terminal.get_grid_size()
	terminal.remote_feed_stream(PackedByteArray(), grid.x, grid.y, true, false)
	expect(await until(func(): return terminal.image_placements().is_empty()), "Client image state is really discarded before reconnect")
	client.connection.connect_remote(settings.url, settings.token)
	expect(await until(func(): return client.connection.connected and has_image(terminal, 9002) and has_image(terminal, 9003)), "Reconnect restores bytes and file-backed image placements from snapshot")
	terminal.send_text("printf '\\033_Ga=d,d=I,i=9002,q=2\\033\\\\'\r")
	expect(await until(func(): return not has_image(terminal, 9002)), "Image deletion keeps original ID after reconnect")
	terminal.send_text("i=0; while [ $i -lt 180 ]; do printf 'HISTORY_%03d 한글\\n' $i; i=$((i+1)); done\r")
	expect(await until(func(): return "HISTORY_179" in str(terminal.get_text(false).get("text", ""))), "Unicode output advances real terminal scrollback")
	expect("HISTORY_000" in str(terminal.get_text(true).get("text", "")), "History beyond viewport remains available for selection")
	finish()
