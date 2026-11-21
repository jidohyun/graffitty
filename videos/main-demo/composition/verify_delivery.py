#!/usr/bin/env python3
"""Verify the delivered film against the current recording and composition cues."""
import json
import math
from pathlib import Path
import subprocess
import wave

ROOT=Path(__file__).resolve().parent
OUT=ROOT.parents[1]/'artifacts/main-demo'

def read(name): return json.loads((ROOT/name).read_text())

def verify_timestamps(path, frames, fps=60):
    packets=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_packets','-show_entries','packet=pts_time','-of','json',str(path)]))['packets']
    assert len(packets)==frames, 'Video packet count differs from the edit'
    origin=float(packets[0]['pts_time'])
    assert abs(origin)<.02, 'Video must start with the audio'
    assert all(abs(float(packet['pts_time'])-origin-index/fps)<.0015
               for index,packet in enumerate(packets)), f'Video timestamps must advance at {fps} fps'

def verify_markdown_departure(path):
    """Catch a stale recording even when all timestamps and landing frames pass."""
    from refresh_markdown_transition import departure_evidence
    capture=read('capture.json')
    meta=read('markdown-transition.json') if (ROOT/'markdown-transition.json').exists() else None
    take=json.loads((ROOT.parents[2]/(meta['take'] if meta else capture['take'])/'capture.json').read_text())
    transition=next(t for t in take['session_navigation']['transitions'] if t['name']=='Diagram')
    evidence=departure_evidence(transition)
    assert transition['isolated_departure_frames'] > 20, 'Flying glyphs must use isolated screen-space blur'
    if meta:
        assert meta['isolated_departure_frames']==transition['isolated_departure_frames']
        assert evidence==meta['departure_camera']
        assert meta['playback_rate']==1 and not meta['failures']
        assert meta['recorded_frames']+meta['landed_hold_frames']==meta['end_frame']-meta['start_frame']
        assert 'id="markdown-session-transition"' in (ROOT/'index.html').read_text()
        click=meta['click_frame']
    else:
        from edit_decisions import edited_frame
        assert not take['failures']
        # click_frame is logged after the click helper returns; the camera
        # departure starts at the press. Read the frames just before it.
        click=edited_frame(next(f['frame'] for f in transition['camera_frames'] if f['flight']),capture['cuts'])
    # Read the delivered pixels surrounding the click, before appreciable flight.
    # The old neutral-camera flash changed this crop by >13 gray levels twice.
    first=click-9
    raw=subprocess.check_output(['ffmpeg','-v','error','-ss',str(first/60),'-i',str(path),
        '-vf','crop=500:650:380:200,scale=100:130,format=gray','-frames:v','12','-f','rawvideo','-'])
    size=13000
    assert len(raw)==12*size
    frames=[raw[i:i+size] for i in range(0,len(raw),size)]
    changes=[sum(abs(a-b) for a,b in zip(x,y))/size for x,y in zip(frames,frames[1:])]
    assert max(changes)<5, f'Markdown departure contains a camera flash: {changes}'
    # The terminal crop cannot catch a lost custom Chromium background. Check
    # the browser toolbar independently, before appreciable flight translation.
    toolbar=subprocess.check_output(['ffmpeg','-v','error','-ss',str(first/60),'-i',str(path),
        '-vf','crop=570:105:1000:185,scale=190:35,format=gray','-frames:v','12','-f','rawvideo','-'])
    toolbar_size=190*35
    assert len(toolbar)==12*toolbar_size
    toolbar_frames=[toolbar[i:i+toolbar_size] for i in range(0,len(toolbar),toolbar_size)]
    toolbar_changes=[sum(abs(a-b) for a,b in zip(x,y))/toolbar_size for x,y in zip(toolbar_frames,toolbar_frames[1:])]
    assert max(toolbar_changes)<8, f'Markdown toolbar changes at the retained handoff: {toolbar_changes}'
    return {'start_frame':first,'frames':len(frames),'maximum_pixel_change':max(changes),
            'maximum_toolbar_pixel_change':max(toolbar_changes),
            'isolated_departure_frames':transition['isolated_departure_frames'],
            'maximum_camera_rotation_error':evidence['max_rotation_error']}

def verify_mobile_ports(path):
    """Inspect the rendered phone overview, so stale compact footage cannot pass."""
    from PIL import Image
    mobile=read('android-capture.json')
    take=ROOT.parents[2]/mobile['take']
    beat=next(b for b in json.loads((take/'beats.json').read_text())
              if b['action']=='Android: connect Send to Slack')
    at=mobile['start']+mobile['manager']['duration']+.15+beat['seconds']+.5
    raw=subprocess.check_output(['ffmpeg','-v','error','-ss',str(at),'-i',str(path),
        '-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','-'])
    frame=Image.frombytes('RGB',(1920,1080),raw)
    rows=[]
    # The first agent's output column in the fixed phone composition, including
    # its 56 px vertical placement. Measure all five colored socket centers.
    for y in range(466,656):
        pixels=[frame.getpixel((x,y)) for x in range(804,812)]
        if sum(max(rgb)-min(rgb)>50 and max(rgb)>140 for rgb in pixels)>=3:
            rows.append(y)
    groups=[]
    for y in rows:
        if not groups or y>groups[-1][-1]+1: groups.append([])
        groups[-1].append(y)
    centers=[sum(group)/len(group) for group in groups if len(group)>=3]
    assert len(centers)==5, f'Expected five expanded output sockets, found {centers}'
    spacing=[b-a for a,b in zip(centers,centers[1:])]
    assert min(spacing)>=38, f'The delivered phone still has compact ports: {spacing}'
    return {'time':at,'port_centers_y':centers,'minimum_spacing_pixels':min(spacing),
            'capture_backend':'desktop-mobile'}

def main():
    capture=read('capture.json')
    from edit_decisions import require_original_speed
    require_original_speed(capture)
    presentation=read('presentation.json')
    assert all(part.strip()[0].isupper() for c in presentation['chapters'] for part in c['text'].split(':') if part.strip()), 'Capitalize chapter titles and descriptions'
    assert capture['native_window']['cursor_return_frames'] == 45
    assert capture['native_window']['cursor_scale'] == 1.344
    assert capture['native_window']['click_intro']['frames'] == 22
    assert capture['native_window']['click_intro']['playback_rate'] == 1.0
    voices=read('demo-narration-cues.json')['cues']
    assert {v['id'] for v in voices} == {line['id'] for line in read('demo-narration.json')['lines']}
    # SystemOne opens the graph chapters on its arrived graph. Parallel and
    # Graph Protocol each begin with a real sidebar click from the previous one.
    node_sessions = [read(f'{name}-capture.json') for name in ['systemone', 'parallel', 'protocol']]
    for before, after in zip(node_sessions, node_sessions[1:]):
        assert before['workspace_source_frames'][1] == after['workspace_source_frames'][0], 'Session transitions must retain consecutive source frames'
    assert {b['action']:b['frame'] for b in node_sessions[0]['beats']}['SystemOne: intro'] == 0
    assert not node_sessions[0]['session_navigation']['transitions']
    for index, chapter in enumerate(node_sessions):
        assert chapter['continuous_workspace']['world'] == 'bistro'
        assert chapter['continuous_workspace']['session'].startswith('$')
        assert chapter['continuous_workspace']['prepared_sessions'] == 4
        if index > 0:
            actions = {b['action']:b['frame'] for b in chapter['beats']}
            label = 'Parallel' if index == 1 else 'Protocol'
            intro = 'three workers running' if index == 1 else 'inspector'
            assert actions[label + ': session click'] == 0
            assert actions[label + ': ' + intro] > 0
            transitions = chapter['session_navigation']['transitions']
            assert len(transitions) == 1 and transitions[0]['compact']
            assert transitions[0]['departure'] and transitions[0]['arrival']
            assert transitions[0]['to'] == chapter['continuous_workspace']['session']
    assert not capture['failures']
    assert capture['filetree_toggle']['active'] and capture['filetree_toggle']['color'] == '#4da3ff'
    assert capture['filetree_toggle']['background'] == 'none'
    duration=capture['timeline_duration']+read('android-capture.json')['duration']
    routing=read('systemone-capture.json')
    assert abs(routing['start']-duration)<1/120, 'SystemOne follows Android'
    assert not routing['failures'] and routing['routing_edges']==3 and routing['route']=='claude'
    assert routing['jev_title']=='SystemOne JEV', 'The middle node is clearly titled as JEV'
    assert routing['manual_output_style']=='solid', 'Manual Prompt directly emits over a solid wire'
    assert routing['routing_output_style']=='solid', 'SystemOne automatically emits to its chosen output over a solid wire'
    duration+=routing['duration']
    parallel=read('parallel-capture.json')
    assert abs(parallel['start']-duration)<1/120, 'Parallel follows SystemOne'
    duration+=parallel['duration']
    if (ROOT/'protocol-capture.json').exists():
        protocol=read('protocol-capture.json')
        assert abs(protocol['start']-duration)<1/120
        assert protocol['subtitle']=='Graffitty Graph Protocol (GGP): Make your custom node'
        assert protocol['command']=='uv run node.py'
        assert protocol['result']=='HELLO GRAPH' and protocol['delivered']
        assert protocol['original_session_reference'] and not protocol['failures']
        assert protocol['empty_manual_sessions']
        intro=protocol['live_agent_intro']
        assert 0 <= intro['connected_frame'] < intro['prompt_start_frame'] < intro['submitted_frame'] < intro['response_started_frame'] < intro['received_frame'] < round(protocol['duration']*60)
        duration+=protocol['duration']
    watcher=read('watcher-capture.json')
    assert abs(watcher['start']-duration)<1/120, 'Watcher must immediately follow uppercase'
    assert watcher['delivered'] and watcher['messages']==1 and watcher['silent_before_email'] and watcher['claude_prepared'] and watcher['podcast_created']
    assert not watcher['failures'] and watcher['example']=='examples/watcher-node/node.py'
    assert watcher['prepared_sessions']==4 and watcher['watcher_session'].startswith('$')
    assert watcher['beats'][0]['action']=='Watcher: session click'
    transition, = watcher['session_navigation']['transitions']
    assert transition['to'] == watcher['watcher_session'] and transition['prepared_count'] == 4
    assert transition['compact'] and transition['departure'] and transition['arrival']
    intro = next(v for v in voices if v['id'] == 'watcher-intro')
    assert abs(intro['start'] - watcher['start'] - transition['click_frame'] / 60) < 1/120
    assert intro['start'] < watcher['start'] + transition['end_frame'] / 60, 'Begin speaking during the session animation'
    assert watcher['recipient'] == 'claude' and watcher['command'] == 'uv run node.py email-cli wait'
    watcher_take = ROOT.parents[2] / watcher['take']
    watcher_beats = {b['action']: b['frame'] for b in watcher['beats']}
    assert 'Watcher: ready' not in watcher_beats and not any(v['id'] == 'watcher-ready' for v in voices)
    assert watcher_beats['Watcher: wire connected'] - watcher_beats['Watcher: connect'] <= 60, 'Connect during the spoken instruction without waiting'
    watcher_evidence = json.loads((watcher_take / 'watcher-evidence.json').read_text())
    assert watcher_beats['Watcher: result'] == watcher_evidence['released_frame'], 'Narrate the new email when it actually arrives'
    for chapter in [*node_sessions, watcher]:
        log = (ROOT.parents[2] / chapter['take'] / 'godot.log').read_text()
        assert 'PASS Manual graph framing stays fixed after navigation without new typing' in log
        assert 'FAIL Manual graph framing' not in log
    assert 'PASS The submitted GGP prompt does not restart adaptive zoom after manual navigation' in (ROOT.parents[2] / protocol['take'] / 'godot.log').read_text()
    assert 'PASS The Payload Inspector remains fully visible while Claude responds' in (ROOT.parents[2] / protocol['take'] / 'godot.log').read_text()
    email = json.loads((watcher_take / 'received-email.json').read_text())
    assert email['event']['text'] == (watcher_take / 'email.txt').read_text()
    assert email['duration'] > 3 and (watcher_take / email['podcast']).stat().st_size > 44
    with wave.open(str(watcher_take / email['podcast'])) as podcast:
        assert abs(podcast.getnframes() / podcast.getframerate() - email['duration']) < 1/24000
    duration+=watcher['duration']
    localized = {f'main-demo.{p.stem}.webm' for p in (ROOT/'locales').glob('*.json')}
    competing = [p.name for p in OUT.iterdir() if p.suffix in {'.mp4', '.webm'}
                 and 'demo' in p.name and p.name not in localized | {'main-demo.webm'}]
    assert not competing, f'Unexpected demo exports: {competing}'
    if (ROOT/'filetree-transition.json').exists():
        transition=read('filetree-transition.json')
        assert transition['direct_pointer'] and transition['effects_settled'] and not transition['failures']
        assert transition['pointer_traveled'] <= transition['pointer_distance'] * 1.06
        assert 'id="filetree-direct-transition"' in (ROOT/'index.html').read_text()
    expected=round(duration*60)
    outputs={}
    webm_report=json.loads((OUT/'main-demo.webm.json').read_text())
    assert webm_report['frames']==expected
    assert webm_report['output_bytes']==(OUT/'main-demo.webm').stat().st_size
    markdown_departure=verify_markdown_departure(OUT/'main-demo.webm')
    mobile_ports=verify_mobile_ports(OUT/'main-demo.webm')
    deliveries = [('main-demo.webm', 1920, 1080, 60, expected)]
    deliveries.extend((name, 1280, 720, 30, expected // 2) for name in sorted(localized) if (OUT/name).exists())
    for name, width, height, fps, frames in deliveries:
        path=OUT/name
        verify_timestamps(path,frames,fps)
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','stream=codec_type,codec_name,width,height,r_frame_rate,nb_frames,sample_rate,channels:format=duration,size','-of','json',str(path)]))
        video=next(s for s in probe['streams'] if s['codec_type']=='video')
        audio=next(s for s in probe['streams'] if s['codec_type']=='audio')
        assert (video['width'],video['height'],video['r_frame_rate'])==(width,height,f'{fps}/1')
        assert audio['channels']==2 and audio['sample_rate']=='48000'
        # Rendering/export already decoded and counted every video frame.
        # Check the final mux's entire audio without repeating video work.
        # WebM already delimits Opus packets.
        #
        # Skip the redundant elementary parser, which FFmpeg 8.0.1 incorrectly
        # runs on an empty EOF packet.
        framing=['-fflags','+noparse+nofillin'] if path.suffix=='.webm' else []
        subprocess.run(['ffmpeg','-v','error','-xerror',*framing,'-i',str(path),'-vn','-f','null','-'],check=True)
        outputs[name]=probe
    keys=presentation['shortcuts']
    assert len({k['group'] for k in keys})==6
    command=[k for k in keys if k['label']=='Open command line']
    assert command[0]['combo'] == 'ctrl' and command[-1]['combo'] == 'ctrl+a+comma+colon', 'Show Ctrl A, then : for the command line'
    assert all(k.get('label') for k in keys)
    assert {k['label'] for k in keys if k['combo']=='2+minus'} == {'Send to pane 2'}
    assert not any('shift' in k['combo'] for k in keys)
    assert len({k['group'] for k in keys if k['combo']=='cmd+alt+enter'}) == 2
    for a,b in zip(keys,keys[1:]):assert a['start']+a['duration']<=b['start']+1e-6
    native=next(v for v in voices if v['id']=='chromium-native')
    assert abs(native['start']-capture['native_window']['timeline_start'])<1/60
    ownership = next(v for v in voices if v['id']=='chromium-ownership')
    assert ownership['start'] - native['end'] >= 3.0, 'Leave three seconds before the ownership narration'
    path_voice=next(v for v in voices if v['id']=='filetree-send-path')
    assert path_voice['end']<=next(c['start'] for c in capture['chapters'] if c['text']=='Chromium: markdown preview')
    from edit_decisions import edited_frame
    beats={b['action']:b['frame'] for b in capture['beats']}
    approach, text_ready, png_ready = [edited_frame(beats[action], capture['cuts']) / 60 for action in
        ['Point to plan.txt', 'Text viewer ready', 'Image viewer ready']]
    filetree_open = edited_frame(beats['Chapter: filetree: open text files in nvim, and image/video/pdf in chromium'], capture['cuts']) / 60
    # The divider, camera easing and pointer approach belong to one recording.
    # A cut can put the pointer on the right word while still truncating motion.
    release_start = beats['Filetree rename camera settled']
    editor = beats['Text viewer ready']
    continuous_frames = edited_frame(editor, capture['cuts']) - edited_frame(release_start, capture['cuts'])
    assert continuous_frames == editor - release_start, 'Preserve every frame from the divider drag through Neovim opening'
    spans = capture.get('reused_recordings', [])
    if spans:
        assert any(s['timeline_start_frame'] <= release_start and
                   editor < s['timeline_start_frame'] + s['end_frame'] - s['start_frame']
                   for s in spans), 'Keep the divider and Neovim reveal in one source span'
    voice = next(v for v in voices if v['id'] == 'filetree-open')
    master = next(v for v in read('demo-audio.json')['voices'] if v['id'] == voice['id'])
    words = {w['text'].lower(): (voice['start'] + w['start'], voice['start'] + w['end']) for w in master['words']}
    assert 0 <= approach - filetree_open <= 1, 'Head to plan.txt as soon as the divider release finishes'
    assert abs(approach - words['opening'][0]) <= 1/60, 'Start speaking on the approach to plan.txt'
    assert approach <= text_ready <= words['neovim'][1], 'Show Neovim during its spoken phrase'
    assert words['chromium'][0] <= png_ready < words['chromium'][1], 'Reveal the PNG on the word Chromium'
    split_moves = capture['split_pointer_moves']
    assert [move['part'] for move in split_moves] == ['split_right', 'split_down', 'split_right'], 'Both opening splits and the automation split must be measured'
    for move in split_moves:
        points = [move['from'], *move['points'], move['to']]
        travelled = sum(math.dist(a, b) for a, b in zip(points, points[1:]))
        direct = math.dist(points[0], points[-1])
        assert travelled <= direct * 1.02 + 1, 'Split clicks must approach the button directly without a hover detour'
        direction = [b - a for a, b in zip(points[0], points[-1])]
        progress = [sum((v - a) * d for v, a, d in zip(point, points[0], direction)) / direct for point in points]
        assert all(b >= a - .1 for a, b in zip(progress, progress[1:])), 'Split pointer movement must never backtrack'
        assert 0 < move['end_frame'] - move['start_frame'] <= 24
    assert beats['MarkdownPreview submitted'] - beats['MarkdownPreview typed; hold before Enter'] <= 18, 'Submit MarkdownPreview promptly'
    assert beats['Type the Markdown heading'] - beats['Markdown preview ready'] <= 30, 'Start editing as soon as the preview is ready'
    assert beats['Open PDF from filetree'] == beats['Video playback ended'], 'Move on immediately when video.webm ends'
    assert 0 <= beats['Chapter: filetree: open text files in nvim, and image/video/pdf in chromium'] - beats['Filetree rename camera settled'] <= 60, 'Keep the pause after filename editing below one second'
    line_move = edited_frame(beats['Ownership: move right chromium with connecting line'], capture['cuts']) / 60
    assert abs(line_move - ownership['start'] - 14.36) < .1, 'Move the right chromium on connecting line'
    loop_end = edited_frame(beats['Ownership: right chromium movement complete'], capture['cuts']) / 60
    assert 2.5 <= loop_end - line_move <= 3.2, 'Show the complete circular drag at original speed'
    parallel = read('parallel-capture.json')
    assert parallel['wire_styles'] == {'turn_completed':'solid','combined':'solid'}
    assert parallel['playback_rate'] == 1.0
    assert {v['id'] for v in voices if v['id'].startswith('parallel-')} == {'parallel-intro','parallel-combined'}
    protocol_beats = {b['action']: b['seconds'] for b in protocol['beats']}
    connect_voice = next(v for v in voices if v['id'] == 'protocol-connect')
    send_voice = next(v for v in voices if v['id'] == 'protocol-send')
    run_voice = next(v for v in voices if v['id'] == 'protocol-run')
    assert 0 <= connect_voice['start'] - run_voice['end'] <= .15, 'Run and Connect should flow together'
    assert abs(connect_voice['start'] - protocol['start'] - protocol_beats['Protocol: connect']) < 1/60
    connected = protocol['start'] + protocol_beats['Protocol: connections complete']
    assert connected <= connect_voice['end'] + 1/60, 'Connect both nodes during the spoken instruction'
    assert 1 <= send_voice['start'] - connected <= 2, 'Leave one to two seconds before Send the message'
    submitted = protocol['start'] + protocol_beats['Protocol: message submitted']
    assert protocol_beats['Protocol: follow message to inspector'] - protocol_beats['Protocol: message submitted'] >= 1.8, 'Show both transfers before the inspector close-up'
    written = protocol['start'] + protocol_beats['Protocol: message written']
    assert send_voice['start'] <= written <= send_voice['end'], 'Type hello graph during Send the message'
    assert submitted - written >= 2.0, 'Hold the written message for two seconds before revealing the route and sending'
    assert next(v for v in read('demo-narration.json')['lines'] if v['id'] == 'protocol-run')['text'] == 'Run it.'
    status = next(v for v in voices if v['id']=='workspace-status')
    stash = next(v for v in voices if v['id']=='workspace-stash')
    stash_at = edited_frame(beats['Workspace: stash old pane'], capture['cuts']) / 60
    assert beats['Workspace: pane status'] < beats['Workspace: stash old pane']
    assert status['end'] <= stash_at, 'Explain pane status before moving the pane'
    assert abs(stash['start'] - stash_at - .25) < 1/60, 'Say stash on the recorded drag'
    automation = [v for v in voices if v['id'].startswith('chromium-automation')]
    assert len(automation) == 1
    assert automation[0]['start'] >= edited_frame(beats['Chapter: Chromium: automation'],capture['cuts'])/60
    assert automation[-1]['end'] <= native['start'], 'Explain both chromium tests before the native-window narration'
    assert edited_frame(beats['Both chromium tests visible'], capture['cuts']) / 60 <= automation[0]['end']
    assert abs(capture['native_window']['timeline_end'] - native['start'] - 6.4) < 1/60
    captions = read('presentation.json')['subtitles']
    from payload_underlines import cues as payload_cues
    assert presentation['underlines'] == json.loads(json.dumps(payload_cues(ROOT)))
    marks = {c['id']: c for c in presentation['underlines']}
    assert list(marks) == ['inspector-terminal', 'routing-question', 'session-path', 'last-message', 'ggp-import', 'input-port', 'output-port',
                           'uppercase-call', 'send-output', 'uppercase-output',
                           'slack-arrival']
    inspector = marks['inspector-terminal']
    intro = next(v for v in voices if v['id'] == 'protocol-inspector')
    words = next(v for v in read('demo-audio.json')['voices'] if v['id'] == intro['id'])['words']
    payload_word = next(w for w in words if w['text'] == 'Payload')
    assert abs(inspector['start'] - intro['start'] - payload_word['start']) <= 1/120
    assert inspector['end'] == intro['end'], 'Keep the box through the inspector explanation'
    assert inspector['box'] == [924, 240, 632, 606] and inspector['arrow'] is None
    question = marks['routing-question']
    prompt = read('systemone-capture.json')
    prompt = prompt['start'] + next(b['frame'] for b in prompt['beats'] if b['action'] == 'SystemOne: prompt') / 60
    assert question['end'] <= prompt, 'Remove the routing-question mark before the camera leaves JEV'
    android = read('android-capture.json')
    arrival = read('../android-overlay/overlay.json')['arrival_frame'] / 60
    arrival += android['start'] + (android['manager']['duration'] - 1 if android.get('manager') else 0)
    slack = marks['slack-arrival']
    assert slack['voice'] is None and not slack['lines']
    assert 0.28 <= slack['start'] - arrival < 0.28 + 1/60, 'Point at the settled notification'
    assert abs(slack['end'] - arrival - 4.65) < 1/60, 'Remove the arrow when the banner starts closing'
    assert slack['arrow'] == [1330, 206, 'left'], 'Point at the banner from outside the phone'
    for underline in presentation['underlines']:
        if underline['voice'] is None:
            continue
        voice = next(v for v in voices if v['id'] == underline['voice'])
        # The routing question stays marked while the camera holds after the line.
        hold = .75 + 1/60 if underline['id'] == 'routing-question' else 0
        assert voice['start'] < underline['start'] < underline['end'] <= voice['end'] + hold
    # The code walkthrough marks one step at a time: ports, processing, sending.
    assert marks['input-port']['end'] == marks['output-port']['end'] == marks['uppercase-call']['start']
    assert marks['uppercase-call']['end'] == marks['send-output']['start']
    assert all(marks[name]['end'] == next(v for v in voices if v['id'] == marks[name]['voice'])['end']
               for name in ['session-path', 'last-message', 'ggp-import', 'send-output', 'uppercase-output'])
    assert any('which agent is using which browser.' in c['text'] for c in captions)
    assert not any('which agent is using which chromium.' in c['text'] for c in captions)
    navigation = capture['session_navigation']
    assert set(navigation['prepared']) == {'Workspace', 'Filetree', 'Markdown', 'Diagram', 'Automation'}
    assert len({session['place'] for session in navigation['prepared'].values()}) == 5
    assert [t['name'] for t in navigation['transitions']] == ['Filetree', 'Markdown', 'Diagram', 'Automation']
    for transition in navigation['transitions']:
        assert transition['prepared_count'] == 5 and transition['compact']
        assert transition['departure'] and transition['arrival']
        assert transition['from_place'] != transition['to_place'] and transition['camera_distance'] > 1
        assert transition['camera_travel_frames'] > 10
        assert transition['to_place'] == navigation['prepared'][transition['name']]['place']
        start, end = transition['start_frame'], transition['end_frame']
        assert edited_frame(end, capture['cuts']) - edited_frame(start, capture['cuts']) == end - start
    tab_start=beats['Select the Markdown session']
    tab_click=beats['Markdown session clicked']
    tab_ready=beats['Markdown session ready for typing']
    assert tab_start < tab_click <= tab_ready
    assert edited_frame(tab_ready,capture['cuts'])-edited_frame(tab_start,capture['cuts']) == tab_ready-tab_start, 'The Markdown session click and transition must remain in the delivered edit'
    diagram=next(v for v in voices if v['id']=='chromium-diagram')
    evidence=capture['visual_explanation']
    assert evidence['url'].startswith(('file:///tmp/', 'file:///private/tmp/')) and evidence['url'].endswith('/http-request.html')
    assert evidence['address_bar']==evidence['url']
    assert evidence['stages']==['request','server','render']
    assert evidence['chromium_owner']==int(evidence['terminal'].removeprefix('%'))
    assert evidence['markdown_preserved'] and evidence['markdown_session'] != evidence['diagram_session']
    diagram_actions=['Chapter: Chromium: visual explanations','Diagram: select the prepared session',
                     'Diagram: launch Claude in its session','Diagram: ask Claude for an explanation',
                     'Diagram: local HTML ready','Diagram: explanation complete','Chapter: Chromium: automation']
    diagram_frames=[beats[action] for action in diagram_actions]
    assert diagram_frames==sorted(diagram_frames), 'Preserve Markdown, select the prepared Diagram session, launch Claude, and show the diagram in order'
    assert diagram['end']<=edited_frame(diagram_frames[-1],capture['cuts'])/60
    assert 30 <= diagram_frames[-2]-diagram_frames[-3] <= 45, 'Keep only a brief half-second hold after the finished diagram'
    assert edited_frame(diagram_frames[-1],capture['cuts'])-edited_frame(diagram_frames[0],capture['cuts'])==diagram_frames[-1]-diagram_frames[0], 'Keep the full diagram interaction in the edit'
    transition_start = beats['Diagram: local HTML ready']
    transition_end = beats['Automation: launch Codex']
    assert transition_start < beats['Chapter: Chromium: automation'] < transition_end
    assert edited_frame(transition_end,capture['cuts'])-edited_frame(transition_start,capture['cuts']) == transition_end-transition_start, 'Keep the Automation session click continuous'
    spans = [span for span in capture.get('reused_recordings', [])
             if span['timeline_start_frame'] < transition_end
             and span['timeline_start_frame']+span['end_frame']-span['start_frame'] > transition_start]
    if spans:
        assert len({span['source'] for span in spans}) == 1, 'Do not cut from the diagram to an older automation take'
        for a,b in zip(spans,spans[1:]):
            assert a['end_frame'] == b['start_frame'], 'The diagram-to-automation source frames must be consecutive'
    summary=capture['tabs_summary']
    assert summary['visible'] and summary['tab_count']==len(summary['items'])==2
    assert all(item['pane_count']>0 and 'resources' in item and 'agents' in item for item in summary['items'])
    assert sum(agent['count'] for item in summary['items'] for agent in item['agents'] if agent['status']=='running')>=2
    summary_voice=next(v for v in voices if v['id']=='tabs-summary')
    assert summary_voice['end']<=edited_frame(beats['Tabs: status summary complete'],capture['cuts'])/60
    assert beats['Chapter: tabs: status at a glance'] < beats['Tabs: all statuses visible'] < beats['Tabs: status summary complete'] < beats['Finished']
    assert summary['search']['query']=='HTTP'
    assert summary['search']['match_color']=='#ffd078'
    assert any(row.get('pane_key')==summary['search']['pane'] for row in summary['search']['rows'])
    partial_matches=[]
    for row in summary['search']['rows']:
        if row.get('kind') == 'pane':
            assert row['match_indices'], 'Pane search highlights the actual match, including typo-tolerant results'
            assert all(0 <= index < len(row['title']) for index in row['match_indices']), 'Highlights must refer to displayed characters'
            if ''.join(row['title'][i] for i in row['match_indices']).upper() != 'HTTP':
                partial_matches.append(row['pane_key'])
    assert partial_matches, 'The delivered search must demonstrate typo matches, not only exact HTTP results'
    recording=summary['search'].get('recording')
    if recording:
        assert (ROOT/recording['asset']).is_file()
        assert set(partial_matches)=={row['pane_key'] for row in recording['partial_matches']}
        source = (ROOT/'index.html').read_text()
        assert f'src="{recording["asset"]}"' in source
        assert f'data-start="{recording["start"]:.6f}" data-duration="{recording["duration"]:.6f}"' in source
    command_actions=['Chapter: command line: fuzzy finder built in', 'Command line: fuzzy command selected',
                     'Command line: tab selected', 'Command line: pane selected', 'Command line: demonstration complete']
    command_frames=[beats[action] for action in command_actions]
    assert command_frames==sorted(command_frames) and command_frames[0]>beats['Tabs: status summary complete']
    command_voice=next(v for v in voices if v['id']=='command-line')
    assert command_voice['end']<=edited_frame(command_frames[-1],capture['cuts'])/60
    mobile = read('android-capture.json')
    assert mobile['wire_styles'] == {'turn_completed': 'solid', 'send': 'dashed'}
    assert mobile['navigation']['input'] == 'title_double_tap'
    assert mobile['navigation']['pane_focuses'] > 0 and mobile['navigation']['overview_returns'] > 0
    assert mobile['screen_source_start'] == 0, 'Do not trim past the split-button click'
    assert 'Three-node overview is centered before double-tap navigation' in mobile['checks']
    assert 'Graph setup never detours into a pane close-up' in mobile['checks']
    assert 'Pointer clicks right-split to create one pane' in mobile['checks']
    manager = mobile['manager']
    assert manager['source_cut_frames'] == [], 'Record the shortened manager introduction directly at 1x'
    assert next(v for v in read('demo-narration.json')['lines'] if v['id'] == 'android-intro')['text'].endswith('so you can code wherever you are.')
    assert 'It even has mobile clients' in next(v for v in read('demo-narration.json')['lines'] if v['id'] == 'android-intro')['text']
    for check in ['Workspace manager shows compact stacked server cards',
                  'Centered Graffitty logo is visible',
                  'Sticky Connection and Settings navigation is visible',
                  'Saved Mac displays authenticated macOS artwork',
                  'Three-line card shows hostname, status, then address']:
        assert check in manager['checks']
    assert 'Connecting preserves the Android window dimensions' in manager['checks']
    assert 'Connected viewport fits the fixed capture without clipping' in manager['checks']
    mobile_beats = {b['action']: b['seconds'] for b in json.loads((ROOT.parents[2] / mobile['take'] / 'beats.json').read_text())}
    assert 'Codex and Claude are framed before the handoff' in mobile['checks']
    assert 'Claude and Slack are framed before the review findings' in mobile['checks']
    assert mobile_beats['Android: Codex and reviewer visible together'] <= mobile_beats['Android: completion payload to reviewer'], 'Frame Codex and Claude for the handoff'
    assert mobile_beats['Android: completion payload to reviewer'] < mobile_beats['Android: reviewer and Slack visible together'] < mobile_beats['Android: complete missing-requirements list visible'], 'Frame Claude and Slack before review findings'
    assert mobile_beats['Android: Slack queue and log'] - mobile_beats['Android: complete missing-requirements list visible'] >= 3.0, 'Hold the complete review in the shared view'
    explanation_start = mobile['chapters'][1]['start']
    overview_end = explanation_start + mobile_beats['Android: Claude instructions close-up'] - mobile_beats['Android: connect Turn completed to Receive']
    for role_voice in ['android-wiring', 'android-review']:
        voice = next(v for v in voices if v['id'] == role_voice)
        assert explanation_start <= voice['start'] and voice['end'] <= overview_end, 'Explain the roles in the full graph overview'

    intro = next(v for v in voices if v['id']=='android-intro')
    assert intro['end'] <= mobile['start'] + manager['connect_clicked_at']
    assert 1 < manager['connect_clicked_at'] < manager['connected_at'] < manager['duration']
    assert abs(mobile['duration'] - mobile['base_duration'] - manager['duration'] + 1) < 1/120
    for previous, following in zip(voices,voices[1:]):
        assert previous['end'] <= following['start'], 'Narration clips must not overlap'
    report={'outputs':outputs,'frames':expected,'duration':duration,'voice_count':len(voices),'shortcut_groups':len({k['group'] for k in keys}),
            'direct_split_clicks':len(split_moves),
            'markdown_pacing':{'command_hold_frames':beats['MarkdownPreview submitted'] - beats['MarkdownPreview typed; hold before Enter'],
                               'ready_to_typing_frames':beats['Type the Markdown heading'] - beats['Markdown preview ready'],
                               'submitted_to_typing_frames':beats['Type the Markdown heading'] - beats['MarkdownPreview submitted']},
            'filetree_toggle':capture['filetree_toggle'],
            'shortcut_labels':list(dict.fromkeys(k['label'] for k in keys)),
            'markdown_session':{'start_frame':edited_frame(tab_start,capture['cuts']),
                         'clicked_frame':edited_frame(tab_click,capture['cuts']),
                         'ready_frame':edited_frame(tab_ready,capture['cuts'])},
            'markdown_departure':markdown_departure,
            'mobile_ports':mobile_ports,
            'watcher':{'start':watcher['start'],'duration':watcher['duration'],'recipient':watcher['recipient'],
                       'messages':watcher['messages'],'claude_prepared':watcher['claude_prepared'],
                       'podcast_seconds':email['duration'],
                       'intro_starts_at_click':next(v for v in voices if v['id']=='watcher-intro')['start']-watcher['start']},
            'diagram':{'beats':dict(zip(diagram_actions,[edited_frame(f,capture['cuts']) for f in diagram_frames])), 'narration':diagram, 'evidence':evidence},
            'automation_session_transition':{'start_frame':edited_frame(transition_start,capture['cuts']),
                                     'end_frame':edited_frame(transition_end,capture['cuts']), 'continuous':True},
            'tabs_summary':summary,
            'android_manager':manager,
            'android_wire_styles':mobile['wire_styles'],
            'android_navigation':mobile['navigation'],
            'systemone_route':routing['route'],
            'command_line':dict(zip(command_actions,[edited_frame(f,capture['cuts']) for f in command_frames])),
            'native_narration_offset':native['start']-capture['native_window']['timeline_start'],
            'reused_recordings':capture.get('reused_recordings', []),'decode':'Video frames verified by rendering/export; full WebM audio decode passed with -xerror'}
    folder=OUT/'final-review';folder.mkdir(exist_ok=True)
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['outputs','reused_recordings']},indent=2))

if __name__=='__main__':main()
