#!/usr/bin/env python3
"""Compose a graffitty.nvim demo take into the README video (WebM, MP4 and GIF).

Titles and keycaps reuse the main demo's presentation: the same Open Sans
chapter titles and Keyty-derived keycap chords.

The window is larger than the main demo's, so terminal text stays readable
at README size.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MAIN = REPO / 'videos/main-demo/composition'
sys.path.insert(0, str(MAIN))
import shortcuts
from presentation import TEXT_COLOR, TITLE_ACCENT, title_parts
from render_navigation import codec, probe

OUT = REPO / 'videos/artifacts/graffitty-nvim'
FONT = MAIN / 'assets/OpenSans-Semibold.ttf'
FPS = 60
SOURCE = (2400, 1500)
WINDOW = (176, 86, 1568, 980)
SCALE = WINDOW[2] / SOURCE[0]
RADIUS = 22
BACKGROUND = (21, 24, 31)
TITLE_BOX = (100, 15, 1720, 56)
# Keycaps sit over the sending pane's empty lower rows, left of center.
KEYCAPS = (376, 808)
KEYS = {'-': 'minus', '_': 'underscore'}
# README GIF: like the original tmux-send.nvim GIF, a light 10 fps loop.
GIF_FPS, GIF_WIDTH = 10, 960


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def plate(folder):
    """The main demo's dark desktop, window shadow and hairline, at this size."""
    x, y, w, h = WINDOW
    shadow = Image.new('RGBA', (1920, 1080), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 24, x + w, y + h + 24), RADIUS, fill=(8, 10, 16, 128))
    shadow = shadow.filter(ImageFilter.GaussianBlur(35))
    picture = Image.new('RGBA', (1920, 1080), (*BACKGROUND, 255))
    picture.alpha_composite(shadow)
    ImageDraw.Draw(picture).rounded_rectangle((x - 1, y - 1, x + w, y + h), RADIUS + 1,
                                              outline=(115, 121, 131, 80), width=1)
    picture.convert('RGB').save(folder / 'plate.png')
    mask = Image.new('L', (w * 4, h * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * 4 - 1, h * 4 - 1), RADIUS * 4, fill=255)
    mask.resize((w, h), Image.Resampling.LANCZOS).save(folder / 'mask.png')
    # Traffic lights: 28 px circles at 46 px spacing in the Retina source.
    k = SCALE / .56
    size = (round(69 * k), round(17 * k))
    controls = Image.new('RGBA', (size[0] * 8, size[1] * 8))
    draw = ImageDraw.Draw(controls)
    for i, color in enumerate([(236, 103, 101), (242, 202, 68), (101, 196, 102)]):
        left, top, diameter = (.2 + i * 25.76) * k, .16 * k, 15.68 * k
        draw.ellipse((left * 8, top * 8, (left + diameter) * 8, (top + diameter) * 8), fill=(*color, 255),
                     outline=(*(round(c * 207 / 255) for c in color), 255), width=8)
    controls.resize(size, Image.Resampling.LANCZOS).save(folder / 'traffic.png')
    return (round(x + 11 * k), round(y + 20 * k))


def title_image(text, path):
    width, height = TITLE_BOX[2], TITLE_BOX[3]
    font = ImageFont.truetype(str(FONT), 40)
    assert font.getlength(text) < width - 20, 'Title exceeds its safe width: ' + text
    picture = Image.new('RGBA', (width, height))
    draw = ImageDraw.Draw(picture)
    label, description = title_parts(text)
    left = (width - font.getlength(text)) / 2
    draw.text((left, height / 2), label, font=font, anchor='lm', fill=TITLE_ACCENT)
    draw.text((left + font.getlength(label), height / 2), description, font=font, anchor='lm', fill=TEXT_COLOR)
    picture.save(path)


def keycap_events(demo):
    events = []
    for send in demo['sends']:
        keys = [KEYS.get(ch, ch) for ch in send['keys']]
        press = send['key_frames'][-1] / FPS
        events.append({'keys': keys, 'press': press,
                       'start': press - shortcuts.BUILD_STEP * (len(keys) - 1), 'label': send['label']})
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('take', type=Path)
    parser.add_argument('--no-gif', action='store_true')
    args = parser.parse_args()
    take = args.take.resolve()
    capture = json.loads((take / 'capture.json').read_text())
    demo = json.loads((take / 'demo.json').read_text())
    assert not capture['failures'], capture['failures']
    frames = capture['frames']
    stream = probe(take / 'footage.mp4', count=True)
    assert (stream['width'], stream['height']) == SOURCE and int(stream['nb_read_frames']) == frames
    scenes = demo['scenes']
    assert scenes[0]['start_frame'] == 0 and scenes[-1]['end_frame'] == frames
    for previous, scene in zip(scenes, scenes[1:]):
        assert previous['end_frame'] == scene['start_frame'], 'Scenes are recorded back to back'
    work = HERE / '.render'
    work.mkdir(exist_ok=True)
    traffic_at = plate(work)
    x, y, w, h = WINDOW
    inputs = ['-i', take / 'footage.mp4', '-loop', '1', '-framerate', str(FPS), '-i', work / 'plate.png',
              '-loop', '1', '-framerate', str(FPS), '-i', work / 'mask.png', '-i', work / 'traffic.png']
    graph = [f'[0:v]scale={w}:{h}:flags=lanczos,format=rgba[s]', '[s][2:v]alphamerge[window]',
             f'[1:v][window]overlay={x}:{y}:shortest=1[framed]',
             f'[framed][3:v]overlay={traffic_at[0]}:{traffic_at[1]}[film]']
    previous = 'film'
    for i, scene in enumerate(scenes):
        start = scene['start_frame'] / FPS
        duration = (scene['end_frame'] - scene['start_frame']) / FPS
        path = work / f'title-{i}.png'
        title_image(scene['title'], path)
        index = inputs.count('-i')
        inputs += ['-loop', '1', '-framerate', str(FPS), '-t', str(duration), '-i', path]
        graph.append(f'[{index}:v]format=rgba,fade=t=in:st=0:d=0.28:alpha=1,'
                     f'fade=t=out:st={duration - .18}:d=0.18:alpha=1,setpts=PTS-STARTPTS+{start}/TB[title{i}]')
        rise = f"{TITLE_BOX[1]}+4*(1-min(max((t-{start})/.28,0),1))"
        graph.append(f"[{previous}][title{i}]overlay=x={TITLE_BOX[0]}:y='{rise}':"
                     f"enable='gte(t,{start})*lt(t,{start + duration})':eof_action=pass[titled{i}]")
        previous = f'titled{i}'
    cues = shortcuts.stages(HERE, keycap_events(demo), *KEYCAPS)
    key_inputs, key_filters, previous = shortcuts.render_inputs(HERE, cues, inputs.count('-i'), previous)
    inputs += key_inputs
    graph += key_filters
    # Composite once, losslessly. Each delivery encodes from this master; the
    # GIF in particular stays small only when unchanged pixels stay identical.
    master = work / 'composite.mkv'
    run(['ffmpeg', '-v', 'error', '-y', *inputs, '-filter_complex', ';'.join(graph), '-map', f'[{previous}]',
         '-frames:v', frames, '-an', '-c:v', 'libx264rgb', '-qp', '0', '-preset', 'ultrafast', master])
    assert int(probe(master, count=True)['nb_read_frames']) == frames
    OUT.mkdir(parents=True, exist_ok=True)
    film = OUT / 'graffitty-nvim-demo.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', master, '-an', *codec('webm'), '-pix_fmt', 'yuv420p', film])
    assert int(probe(film, count=True)['nb_read_frames']) == frames
    # GitHub plays MP4 attachments inline; 30 fps keeps the upload small.
    mp4 = OUT / 'graffitty-nvim-demo.mp4'
    run(['ffmpeg', '-v', 'error', '-y', '-i', master, '-vf', 'fps=30', '-c:v', 'libx264', '-preset', 'slow',
         '-crf', '22', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', mp4])
    outputs = [film, mp4]
    if not args.no_gif:
        gif = OUT / 'graffitty-nvim-demo.gif'
        palette = work / 'palette.png'
        scale = f'fps={GIF_FPS},scale={GIF_WIDTH}:-1:flags=lanczos'
        run(['ffmpeg', '-v', 'error', '-y', '-i', master, '-vf', f'{scale},palettegen=max_colors=128:stats_mode=diff', palette])
        run(['ffmpeg', '-v', 'error', '-y', '-i', master, '-i', palette, '-lavfi',
             f'{scale}[v];[v][1:v]paletteuse=dither=none:diff_mode=rectangle', gif])
        outputs.append(gif)
    report = {'take': str(take.relative_to(REPO)), 'frames': frames, 'seconds': frames / FPS,
              'window': WINDOW, 'keycaps': KEYCAPS, 'scenes': [
                  {'title': s['title'], 'start': s['start_frame'] / FPS, 'end': s['end_frame'] / FPS} for s in scenes],
              'sends': len(demo['sends']), 'graffitty_nvim_commit': capture.get('graffitty_nvim_commit'),
              'outputs': {p.name: p.stat().st_size for p in outputs}}
    (OUT / 'graffitty-nvim-demo.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['outputs'], indent=2))


if __name__ == '__main__':
    main()
