"""Gold callouts timed to narration or recorded delivery events."""
import json
import math
import subprocess

from PIL import Image, ImageDraw

COLOR = '#ffd479'
BOX_STROKE = 5
ARROW_SIZES = {'left': (150, 40), 'up': (40, 90), 'down': (40, 90)}
# Coordinates belong to the current Bistro take, in the 1920 × 1080
# composition; the camera holds still through each line.
#
# A cue starts on its word and lasts until its line ends, or until the word
# that starts the next step of the code walkthrough. A number instead holds it
# that many seconds past the line, while the camera still rests on it.
#
# Underlines are (x, y, width); an arrow gives its image's top-left corner and
# the direction it points.
CUES = [
    # "based on your question": JEV's routing question, held until the prompt.
    ('routing-question', 'systemone-intro', 'based', .75, [(426, 472, 514)], (944, 440, 'left')),
    # The inspector's session path wraps onto a second terminal row.
    ('session-path', 'protocol-payload', 'session', None, [(744, 582, 582), (616, 601, 298)], (1080, 478, 'down')),
    ('last-message', 'protocol-payload', 'last', None, [(711, 742, 482)], (940, 638, 'down')),
    # Measured against the fresh take, including the wrapped output declaration.
    ('ggp-import', 'protocol-code', 'GGP', None, [(500, 326, 358)], (700, 328, 'up')),
    ('input-port', 'protocol-ports', 'input', 'process', [(723, 481, 690)], (1062, 367, 'down')),
    ('output-port', 'protocol-ports', 'output', 'process', [(738, 512, 771), (426, 541, 267)], (1062, 514, 'up')),
    ('uppercase-call', 'protocol-ports', 'process', 'send', [(947, 701, 310)], (1062, 582, 'down')),
    ('send-output', 'protocol-ports', 'send', None, [(485, 701, 365)], (621, 703, 'up')),
    # The short value is easy to miss in the JSON, so its arrow sits to its right.
    ('uppercase-output', 'protocol-result', 'uppercase', None, [(711, 812, 95)], (827, 780, 'left')),

]


def cues(root):
    placed = {c['id']: c for c in json.loads((root / 'demo-narration-cues.json').read_text())['cues']}
    voices = {v['id']: v for v in json.loads((root / 'demo-audio.json').read_text())['voices']}

    def spoken(voice, word):
        start = next(w for w in voices[voice]['words'] if w['text'].rstrip('.,') == word)['start']
        return round((placed[voice]['start'] + start) * 60) / 60
    def ending(voice, until):
        if isinstance(until, str): return spoken(voice, until)
        if until is None: return placed[voice]['end']
        return round((placed[voice]['end'] + until) * 60) / 60
    result = [dict(id=name, voice=voice, start=spoken(voice, word),
                 end=ending(voice, until), lines=lines, arrow=list(arrow))
            # Chapters are appended one at a time during a full rebuild.
            for name, voice, word, until, lines, arrow in CUES if voice in placed]
    if 'protocol-inspector' in placed:
        # The opening two-pane view holds still until the payload close-up.
        # Enclose the inspector terminal, leaving its text and source visible.
        result.insert(0, dict(id='inspector-terminal', voice='protocol-inspector',
                             start=spoken('protocol-inspector', 'Payload'),
                             end=placed['protocol-inspector']['end'], lines=[], arrow=None,
                             box=[924, 240, 632, 606]))
    if 'android-slack' in placed:
        android = json.loads((root / 'android-capture.json').read_text())
        overlay = json.loads((root.parent / 'android-overlay/overlay.json').read_text())
        # The manager replaces the overlay's first second. Use the recorded
        # delivery cue, even when the narration finishes before the banner.
        prefix = android['manager']['duration'] - 1 if android.get('manager') else 0
        arrival = round((android['start'] + prefix) * 60) + overlay['arrival_frame']
        # Wait for the 0.28 s entrance; leave when the 4.65 s exit begins.
        # The arrow sits outside the phone, level with the banner's centre.
        result.append(dict(id='slack-arrival', voice=None, start=(arrival + 17) / 60,
                           end=(arrival + 279) / 60, lines=[], arrow=[1330, 206, 'left']))
    return result


def asset(cue):
    return f'assets/callout-{cue["id"]}.webm'


def bounds(cue):
    x, y, direction = cue['arrow']
    w, h = ARROW_SIZES[direction]
    rectangles = [(x, y, w, h)] + [(a, b, c, 3) for a, b, c in cue['lines']]
    left = min(r[0] for r in rectangles) - 8
    top = min(r[1] for r in rectangles) - 8
    width = max(r[0] + r[2] for r in rectangles) - left + 8
    height = max(r[1] + r[3] for r in rectangles) - top + 8
    return left, top, math.ceil(width / 2) * 2, math.ceil(height / 2) * 2


def progress(t, start, duration):
    return min(1., max(0., (t - start) / duration))


def frame(cue, t, scale=3):
    """One seek-safe vector frame, shared by the preview and delivery assets.

    Draw-on and head-arrival settle follow the registry hw-arrow vocabulary,
    with the handwritten wobble/boil removed for a steady technical callout.
    """
    left, top, width, height = bounds(cue)
    picture = Image.new('RGBA', (width * scale, height * scale))
    draw = ImageDraw.Draw(picture)
    duration = cue['end'] - cue['start']
    opacity = progress(t, 0, .06) * (1 - progress(t, duration - .15, .15))

    def line(points, stroke, alpha=1):
        if alpha * opacity <= 0: return
        points = [((x-left)*scale, (y-top)*scale) for x,y in points]
        for extra, color in [(2, (0,0,0,round(95*opacity*alpha))),
                             (0, (255,212,121,round(255*opacity*alpha)))]:
            size = (stroke+extra)*scale
            draw.line(points, fill=color, width=round(size), joint='curve')
            for x,y in [points[0], points[-1]]:
                draw.ellipse((x-size/2,y-size/2,x+size/2,y+size/2),fill=color)

    x,y,direction = cue['arrow']
    w,h = ARROW_SIZES[direction]
    if direction == 'left': tail,tip = (x+w-8,y+h/2),(x+5,y+h/2)
    elif direction == 'up': tail,tip = (x+w/2,y+h-8),(x+w/2,y+5)
    else: tail,tip = (x+w/2,y+8),(x+w/2,y+h-5)
    length = math.dist(tail,tip)
    dx,dy = (tip[0]-tail[0])/length,(tip[1]-tail[1])/length
    amount = 1-(1-progress(t,0,.2))**3
    line([tail,(tail[0]+dx*length*amount,tail[1]+dy*length*amount)],3)
    head = progress(t,.12,.16)
    # A single 3px forward overshoot, settled by 360ms; no repeated bounce.
    nudge = 3 * math.sin(math.pi * progress(t,.16,.2))
    tx,ty = tip[0]+dx*nudge,tip[1]+dy*nudge
    line([(tx-dx*15-dy*10,ty-dy*15+dx*10),(tx,ty),
          (tx-dx*15+dy*10,ty-dy*15-dx*10)],3,head)
    for index,(x,y,width) in enumerate(cue['lines']):
        reveal = 1-(1-progress(t,.2+index*.06,.24))**3
        if reveal > 0: line([(x,y),(x+width*reveal,y)],2)
    return picture.resize((bounds(cue)[2],bounds(cue)[3]),Image.Resampling.LANCZOS)


def render_assets(root, cues):
    for cue in cues:
        if cue['arrow'] is None: continue
        _,_,width,height = bounds(cue)
        count = round((cue['end']-cue['start'])*60)
        command = ['ffmpeg','-v','error','-y','-f','rawvideo','-pix_fmt','rgba',
                   '-s',f'{width}x{height}','-r','60','-i','pipe:0','-an',
                   '-c:v','libvpx-vp9','-lossless','1','-cpu-used','4',
                   '-row-mt','1','-pix_fmt','yuva420p',str(root/asset(cue))]
        with subprocess.Popen(command,stdin=subprocess.PIPE) as process:
            for n in range(count): process.stdin.write(frame(cue,n/60).tobytes())
            process.stdin.close()
            assert process.wait()==0


def html(cues):
    lines = ['    <!-- payload-underlines:start -->']
    for cue in cues:
        timing = (f'data-start="{cue["start"]:.6f}" data-duration="{cue["end"]-cue["start"]:.6f}" '
                  f'data-track-index="7" data-track-kind="overlay"')
        if cue.get('box'):
            x,y,width,height = cue['box']
            lines.append(f'    <div id="payload-{cue["id"]}-box" class="clip" {timing} '
                         f'aria-hidden="true" style="position:absolute;left:{x}px;top:{y}px;'
                         f'width:{width}px;height:{height}px;box-sizing:border-box;'
                         f'border:{BOX_STROKE}px solid {COLOR};z-index:9;pointer-events:none"></div>')
        if cue['arrow'] is None: continue
        x,y,width,height = bounds(cue)
        lines.append(f'    <video id="payload-{cue["id"]}-callout" class="clip" src="{asset(cue)}" '
                     f'muted playsinline {timing} data-media-start="0" aria-hidden="true" '
                     f'style="position:absolute;left:{x}px;top:{y}px;width:{width}px;'
                     f'height:{height}px;z-index:9;pointer-events:none"></video>')
    return '\n'.join(lines + ['    <!-- payload-underlines:end -->'])


def render_inputs(root, cues, first_input, previous):
    """Use the same alpha animation in FFmpeg and the HTML preview."""
    inputs, result = [], []
    for cue in cues:
        enable = f'enable=\'gte(t,{cue["start"]})*lt(t,{cue["end"]})\''
        if cue.get('box'):
            x,y,width,height = cue['box']
            following = f'boxed_{cue["id"].replace("-", "_")}'
            result.append(f'[{previous}]drawbox=x={x}:y={y}:w={width}:h={height}:'
                          f'color={COLOR}:t={BOX_STROKE}:{enable}[{following}]')
            previous = following
        if cue['arrow'] is None: continue
        x,y,_,_ = bounds(cue)
        name = cue['id'].replace('-','_')
        number = first_input+inputs.count('-i')
        result.append(f'[{number}:v]setpts=PTS-STARTPTS+{cue["start"]}/TB[callout_{name}]')
        following = f'arrowed_{name}'
        result.append(f'[{previous}][callout_{name}]overlay=x={x}:y={y}:{enable}:eof_action=pass[{following}]')
        # Native VP9 decoding drops the alpha plane; libvpx preserves it.
        inputs += ['-c:v','libvpx-vp9','-i',str(root/asset(cue))]
        previous = following
    return inputs,result,previous
