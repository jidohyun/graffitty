extends SceneTree
var actions: Array[String] = []
var failures := 0
func check(ok: bool, what: String):
    print(('PASS ' if ok else 'FAIL ') + what)
    if not ok: failures += 1
func _initialize(): call_deferred('run')
func key(term, code: int, pressed: bool = true, echo: bool = false, command: bool = false):
    var e := InputEventKey.new()
    e.keycode = code
    e.pressed = pressed
    e.echo = echo
    e.meta_pressed = command
    term.get_viewport().push_input(e)
func run():
    var term: Control = ClassDB.instantiate('Terminal')
    term.remote_mode = true
    term.use_custom_key_bindings = true
    term.size = Vector2(640,400)
    term.shortcut_action.connect(func(action): actions.append(action))
    var sequences: Array[Dictionary] = [
        {'keys':PackedInt64Array([KEY_G,KEY_G]),'action':'increase_font_size'},
        {'keys':PackedInt64Array([-1,KEY_F]),'action':'decrease_font_size'}]
    var table_bindings: Array[Dictionary] = [{'keys':PackedInt64Array([KEY_R]),'action':'reset_font_size'}]
    term.key_bindings = {KEY_T:'activate_key_table:font'}
    term.configure_advanced({'cursor_blink':0,'key_sequences':sequences,'leader':KEY_SPACE,'key_tables':{'font':{'bindings':table_bindings,'one_shot':true,'timeout_ms':1000}}})
    root.add_child(term)
    term.grab_focus()
    await create_timer(1).timeout
    key(term,KEY_G)
    key(term,KEY_G,false)
    key(term,KEY_G)
    key(term,KEY_G,false)
    await process_frame
    check(actions == ['increase_font_size'],'New extension dispatches a configured key sequence through Godot adapter')
    key(term,KEY_SPACE)
    key(term,KEY_SPACE,false)
    key(term,KEY_F)
    key(term,KEY_F,false)
    await process_frame
    check(actions == ['increase_font_size','decrease_font_size'],'Leader dictionary is parsed and dispatched by new extension')
    key(term,KEY_T)
    key(term,KEY_T,false)
    key(term,KEY_R)
    key(term,KEY_R,false)
    await process_frame
    check(actions == ['increase_font_size','decrease_font_size','reset_font_size'],'Transient table activation and lookup work through new extension')
    key(term,KEY_R)
    key(term,KEY_R,false)
    await process_frame
    check(actions.size() == 3,'One-shot table is removed after its action')
    # Exercise OS-style key echoes through the focused native control, including
    # its consumed-key tracking. A binding lookup alone cannot catch this bug.
    term.key_bindings = {
        KEY_MASK_META | KEY_EQUAL: 'increase_font_size',
        KEY_MASK_META | KEY_MINUS: 'decrease_font_size',
        KEY_MASK_META | KEY_0: 'reset_font_size',
    }
    for binding in [[KEY_EQUAL, 'increase_font_size'], [KEY_MINUS, 'decrease_font_size']]:
        actions.clear()
        key(term, binding[0], true, false, true)
        for i in 3:
            key(term, binding[0], true, true, true)
        await process_frame
        check(actions == [binding[1], binding[1], binding[1], binding[1]], 'Held ' + binding[1] + ' dispatches every echo')
        key(term, binding[0], false, false, true)
        await process_frame
        check(actions.size() == 4, 'Release does not resize')
        # After releasing Cmd, the same character must no longer resize.
        key(term, binding[0])
        key(term, binding[0], true, true)
        key(term, binding[0], false)
        await process_frame
        check(actions.size() == 4, 'Released shortcut does not leak into ordinary typing')
        key(term, binding[0], true, false, true)
        key(term, binding[0], true, true, true)
        key(term, binding[0], false, false, true)
        await process_frame
        check(actions.size() == 6, 'A second hold repeats after release')
    actions.clear()
    key(term, KEY_0, true, false, true)
    for i in 3:
        key(term, KEY_0, true, true, true)
    key(term, KEY_0, false, false, true)
    await process_frame
    check(actions == ['reset_font_size'], 'Held reset dispatches only once')
    term.queue_free()
    await process_frame
    print("NATIVE_BINDING_ADAPTER_PASS" if failures == 0 else "NATIVE_BINDING_ADAPTER_FAIL")
    quit(failures)
