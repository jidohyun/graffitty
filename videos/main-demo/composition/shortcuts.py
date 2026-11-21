"""Frame-synchronized Keyty-derived SVG chords, shared by Studio and exports."""
import html
import json
import re
import subprocess
from edit_decisions import edited_frame

WIDTH, HEIGHT, KEY_HEIGHT = 384, 148, 108
X, Y = 1512, 792
KEY_WIDTHS = {'cmd':114, 'ctrl':126, 'shift':126, 'alt':126, 'enter':154, '2':100, '3':100, 'a':100, 'colon':100,
              'minus':100, 'underscore':100, 'comma':24}
# A sequence separator drawn as a plain glyph between keycaps, not a key.
SEPARATORS = {'comma'}
BUILD_STEP = .18
HOLD, FADE = 3.0, .25
LABELS = {
    ('cmd+alt+enter', 'Workspace: fit Main View'): 'Return to Main View',
    ('cmd+alt+enter', 'Workspace: inspect stashed pane'): 'Restore previous view',
    ('cmd+enter', 'Workspace: inspect stashed pane'): 'Zoom to pane',
    ('cmd+enter', 'Workspace: return from pane inspection'): 'Restore previous view',
}


def width(keys):
    return sum(KEY_WIDTHS[k] for k in keys)+6*(len(keys)-1)


def keycap_image(root, combo, label, pressed=False, offset=0, reveal=1, stamp="", new_from=None):
    keys=combo.split('+')
    new_from=len(keys)-1 if new_from is None else new_from
    x=(426-width(keys))/2+offset
    elements=[]
    legends=json.loads((root/'keycaps/legends.json').read_text())
    for i,key in enumerate(keys):
        if key in SEPARATORS:
            elements.append(f'<g opacity="{reveal if i>=new_from else 1}" fill="#f1f2f4" '
                            f'transform="translate({x} 54)">{legends[key]}</g>')
            x+=KEY_WIDTHS[key]+6
            continue
        variant=key+('-pressed' if pressed and i==len(keys)-1 else '')
        svg=(root/'keycaps'/f'{variant}.svg').read_text()
        # Keep each embedded SVG's paint-server IDs unambiguous.
        svg=svg.replace('id="body"',f'id="body-{i}"').replace('url(#body)',f'url(#body-{i})')
        svg=svg.replace('id="dish"',f'id="dish-{i}"').replace('url(#dish)',f'url(#dish-{i})')
        svg=svg.replace('<svg ',f'<svg x="{x}" y="54" ',1)
        elements.append(f'<g opacity="{reveal if i>=new_from else 1}">{svg}</g>')
        x+=KEY_WIDTHS[key]+6
    legend=legends['label-'+label]
    source=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 426 164">
<!-- Keyty PBT design adaptation; BSD-3-Clause, see keycaps/KEYTY-LICENSE.txt -->
<rect x="0.75" y="0.75" width="424.5" height="162.5" rx="22" fill="#181c21" fill-opacity=".94" stroke="#42484e" stroke-width="1.5"/>
<g fill="#f1f2f4">{legend}</g>
{''.join(elements)}</svg>'''
    stem='shortcut-'+re.sub(r'[^a-z0-9]+','-',label.lower())+'-'+combo.replace('+','-')+('-pressed' if pressed else '')+stamp
    svg_path=root/'assets'/(stem+'.svg'); png_path=svg_path.with_suffix('.png')
    svg_path.write_text(source)
    subprocess.run(['rsvg-convert','-w',str(WIDTH*3),'-h',str(HEIGHT*3),'-o',str(png_path),str(svg_path)],check=True)
    from PIL import Image
    image=Image.open(png_path);image.resize((WIDTH,HEIGHT),Image.Resampling.LANCZOS).save(png_path)
    return str(svg_path.relative_to(root)),str(png_path.relative_to(root))


def cues(root,capture):
    opening_end=next(c['start'] for c in capture['chapters'] if c['text']=='filetree')
    events=[]
    for event in capture.get('shortcut_events',[]):
        press=edited_frame(event['frame'],capture['cuts'])/60
        if event['combo']=='ctrl+a,colon':
            # Prefix, then ':'. Ctrl leads the prefix press like other chords;
            # the comma and ':' appear together at the ':' keydown.
            prefix=edited_frame(event['prefix_frame'],capture['cuts'])/60
            events.append({'keys':['ctrl','a','comma','colon'],'press':press,'start':prefix-BUILD_STEP,
                           'stage_times':[(prefix-BUILD_STEP,1),(prefix,2),(press,4)],'label':event['label']})
        elif press<opening_end:
            # Reuse the accepted camera movement with the current default chord.
            combo = event['combo'].replace('cmd+shift+enter', 'cmd+alt+enter')
            keys=combo.split('+')
            action=next(b['action'] for b in reversed(capture['beats'])
                        if b['frame']<=event['frame'] and b['action'].startswith('Workspace:'))
            events.append({'keys':keys,'press':press,'start':press-BUILD_STEP*(len(keys)-1),
                           'label':LABELS[combo,action]})
    # Teach the explicit pane selector: 2, then -. The existing take sends to
    # the same connected pane with bare -; future takes also type the count.
    path_chapter = next((c for c in capture['chapters']
                         if c['text']=='filetree: send paths to the terminal'), None)
    if path_chapter:
        for event in capture.get('typing_events', []):
            if event['text'] not in ['-', '2-'] or not event['key_frames']:
                continue
            press = edited_frame(event['key_frames'][-1], capture['cuts'])/60
            if path_chapter['start'] <= press < path_chapter['start']+path_chapter['duration']:
                events.append({'keys':['2','minus'],'press':press,'start':press-BUILD_STEP,'label':'Send to pane 2'})
                break
    return stages(root, events)


def stages(root, events, x=X, y=Y):
    """Frame-exact chord stages for key events: {'keys','press','start','label'}."""
    events=sorted(events, key=lambda event:event['start'])
    result=[]
    for i,event in enumerate(events):
        expire=event['press']+HOLD+FADE
        following=events[i+1]['start'] if i+1<len(events) else float('inf')
        end=min(expire,following)
        stages=[]
        stage_times=event.get('stage_times') or [(event['start']+BUILD_STEP*(k-1),k) for k in range(1,len(event['keys'])+1)]
        for start,k in stage_times:
            stages.append((start,'+'.join(event['keys'][:k]),True))
        # The last key releases without clearing the chord; start the 3s hold
        # at the final keydown. New chords replace all prior stages immediately.
        stages.append((event['press']+.10,'+'.join(event['keys']),False))
        for j,(start,combo,pressed) in enumerate(stages):
            stop=min(stages[j+1][0],end) if j+1<len(stages) else end
            if stop<=start: continue
            first,last=round(start*60),round(stop*60)
            # Keep held keys visible. Recenter them over six frames as the new
            # key appears; do not release/re-press Command on every image swap.
            reveal_frames=6 if 0<j<len(stage_times) else 0
            keys=combo.split('+')
            shown=len(stages[j-1][1].split('+')) if j>0 else 0
            segments=[]
            for n in range(min(reveal_frames,last-first)):
                progress=1-(1-n/reveal_frames)**3
                offset=(width(keys)-width(keys[:shown]))/2*(1-progress)
                svg,png=keycap_image(root,combo,event['label'],False,offset,progress,f'-reflow-{n}',shown)
                segments.append((first+n,first+n+1,svg,png,0))
            if first+reveal_frames<last:
                svg,png=keycap_image(root,combo,event['label'],False)
                fade=FADE if j==len(stages)-1 and expire<=following else 0
                segments.append((first+reveal_frames,last,svg,png,fade))
            for begin,finish,svg,png,fade in segments:
                result.append({'combo':combo,'label':event['label'],'start':begin/60,'duration':(finish-begin)/60,
                    'start_frame':begin,'end_frame':finish,
                    'svg':svg,'path':png,'x':x,'y':y,'group':i,'keydown':event['press'],
                    'fade_out':fade})

    return result


def compose(cues):
    # One persistent clip: separately rounded clip windows can leave a whole
    # frame uncovered at e.g. 1015/60, even though their decimal gap is tiny.
    # Only the inner, already-loaded images change at the exact shared times.
    blocks=['    <!-- shortcut-keys:start -->']
    script=['    // shortcut-keys-stage:start']
    if cues:
        lifetime=(max(c['end_frame'] for c in cues)+1)/60
        blocks.append(f'<div id="shortcut-overlay" class="clip" data-start="0" data-duration="{lifetime!r}" '
            'data-track-index="7" data-track-kind="overlay" '
            'style="position:absolute;inset:0;z-index:12;pointer-events:none">')
        for i,cue in enumerate(cues):
            start,end=cue['start_frame']/60,cue['end_frame']/60
            blocks.append(f'<img id="shortcut-keys-{i}" src="{cue["svg"]}" alt="{html.escape(cue["label"])}: {cue["combo"]}" '
                f'style="position:absolute;left:{X}px;top:{Y}px;width:{WIDTH}px;height:{HEIGHT}px;opacity:0">')
            script.append(f'window.__timelines["main"].set("#shortcut-keys-{i}",{{opacity:1}},{start!r});')
            if cue['fade_out']:
                script.append(f'window.__timelines["main"].to("#shortcut-keys-{i}",{{opacity:0,duration:{FADE},ease:"none"}},{end-FADE!r});')
            script.append(f'window.__timelines["main"].set("#shortcut-keys-{i}",{{opacity:0}},{end!r});')
        blocks.append('</div>')
    return '\n'.join(blocks+['    <!-- shortcut-keys:end -->']), '\n'.join(script+['    // shortcut-keys-stage:end'])


def render_inputs(root,cues,first_input,previous):
    inputs,filters=[],[]
    for i,cue in enumerate(cues):
        start=cue['start'];end=start+cue['duration']
        first=cue['start_frame'];last=cue['end_frame']
        inputs+=['-loop','1','-framerate','60','-t',str(cue['duration']),'-i',str(root/cue['path'])]
        fade=f',fade=t=out:st={cue["duration"]-FADE}:d={FADE}:alpha=1' if cue['fade_out'] else ''
        filters.append(f'[{first_input+i}:v]format=rgba{fade},settb=expr=1/60,setpts=N+{first}[keycap{i}]')
        following=f'keyed{i}'
        filters.append(f"[{previous}][keycap{i}]overlay=x={cue['x']}:y={cue['y']}:enable='gte(n,{first})*lt(n,{last})':eof_action=repeat[{following}]")
        previous=following
    return inputs,filters,previous
