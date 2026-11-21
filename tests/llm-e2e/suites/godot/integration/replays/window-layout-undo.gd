extends "remote-window-return.gd"
const Layout=preload("res://scenes/WorkspaceLayout.gd")

func settled(owner: Node) -> void:
	await until(func():return not owner.session_backend.work_pending(),"Window owner acknowledges layout")
	await hold(.25)

func resize_divider(owner: Node, amount: float) -> Dictionary:
	var view: Node=owner.workspace_view
	var group: Dictionary=owner.workspace_layout.tab(owner.workspace_layout.active)
	var before: Dictionary=group.tree.tiles.duplicate(true)
	var dividers: Array=Layout.tile_dividers(group.tree.tiles,Layout.tiling_area(group.tree,view.content_rect()),[],owner.tiling_config.gap)
	if not check(not dividers.is_empty(),"Live split exposes draggable divider"):return {}
	var at: Vector2=dividers[0].rect.get_center()
	if not check(view._start_tile_resize(at),"Actual divider drag starts"):return {}
	view._update_tile_resize(at+Vector2(amount,0))
	var release:=InputEventMouseButton.new()
	release.button_index=MOUSE_BUTTON_LEFT
	release.pressed=false
	view._input(release)
	await settled(owner)
	check(group.tree.tiles!=before,"Committed divider weights change")
	return before

func shortcut(owner: Node, redo := false) -> void:
	var event:=InputEventKey.new()
	event.keycode=KEY_Z
	event.ctrl_pressed=true
	event.shift_pressed=redo
	event.pressed=true
	owner.workspace_view.agent_links.tools._input(event)
	event.pressed=false
	owner.workspace_view.agent_links.tools._input(event)
	await settled(owner)

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	root.gui_embed_subwindows=false
	var releases: Array[Callable]=[]
	releases.append(host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	await host.create_native_window()
	var other: Node
	for candidate in app.hosts:
		if candidate!=host:other=candidate
	if not check(other!=null,"Independent window for resize history"):return
	releases.append(other.effect_control.hold(preload("res://graffitty/effects.gd").NAMES))
	for owner in [host,other]:
		owner.workspace_view.split_window("h")
		if not await until(func():return owner.sessions.size()==2 and owner.sessions.values().all(func(pair):return pair.term.get_shell_pid()>0),"Two live terminals in this native window"):return
		await settled(owner)
	var ids: Dictionary={}
	for owner in [host,other]:
		for id in owner.sessions:ids[id]=owner.sessions[id].term.get_shell_pid()
	var a: Dictionary=await resize_divider(host,130)
	var first_after: Dictionary=host.workspace_layout.tab(host.workspace_layout.active).tree.tiles.duplicate(true)
	var b: Dictionary=await resize_divider(other,-110)
	var second_after: Dictionary=other.workspace_layout.tab(other.workspace_layout.active).tree.tiles.duplicate(true)
	await shortcut(host)
	check(host.workspace_layout.tab(host.workspace_layout.active).tree.tiles==a,"Undo restores first window exact divider weights")
	check(other.workspace_layout.tab(other.workspace_layout.active).tree.tiles==second_after,"First undo leaves sibling layout unchanged")
	await shortcut(other)
	check(other.workspace_layout.tab(other.workspace_layout.active).tree.tiles==b,"Undo restores second window exact divider weights")
	await shortcut(host,true)
	check(host.workspace_layout.tab(host.workspace_layout.active).tree.tiles==first_after,"Redo restores first window exact divider weights")
	check(other.workspace_layout.tab(other.workspace_layout.active).tree.tiles==b,"Redo leaves sibling undo result unchanged")
	for owner in [host,other]:
		for id in owner.sessions:check(owner.sessions[id].term.get_shell_pid()==ids[id],"Window undo retains real shell %d" % id)
	overlay.hide()
	picture(host,"window-one-redo")
	picture(other,"window-two-undo")
