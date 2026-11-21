#!/usr/bin/env python3
"""Build the HyperFrames edit from one recorded take.

    python3 videos/e2e-loop/composition/prepare.py videos/e2e-loop/assets/takes/<name>

1. Trim everything before the "Loop start" beat.
2. Re-encode the footage for seeking.
3. Write `index.html` and `compositions/loop.html` from the take's beats
   and pane rectangles. The edit adds two signs and keeps the spotlight
   on the working side: Claude during implementation, then Codex and
   its Chromium pane during tests.
"""
import argparse, json, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
WIDTH, HEIGHT, FPS = 1920, 1200, 60
SOURCE = 2400  # Recorded width; the edit scales it to WIDTH.
FADE = .6
# The site's window controls (graffitty.com scripts/screenshots.py, tiling): left, top,
# diameter and gap in 2400 px source pixels, with a hairline border.
CONTROLS = (20, 36, 28, 18)
CONTROL_COLORS = ['#ec6765', '#f2ca44', '#65c466']

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('take', type=Path)
args = parser.parse_args()
take = args.take.resolve()
capture = json.loads((take / 'capture.json').read_text())
layout = json.loads((take / 'layout.json').read_text())
beats = {beat['action']: beat['seconds'] for beat in capture['beats']}
start = beats['Loop start']
end = capture['frames'] / capture['fps']
duration = round(end - start, 3)
scale = WIDTH / SOURCE


def at(name):
    return round(beats[name] - start, 3)


def box(name):
    x, y, w, h = (v * scale for v in layout[name])
    return x, y, w, h


claude = box('claude')
chromium, codex = box('chromium'), box('codex')
right = (min(chromium[0], codex[0]), chromium[1], max(chromium[0] + chromium[2], codex[0] + codex[2]) - min(chromium[0], codex[0]),
         codex[1] + codex[3] - chromium[1])

# Phases: Claude from each "Implement N", Codex from each "Test N".
switches, statuses = [], {'implement': [], 'test': []}
builds = sorted(int(name.split()[1]) for name in beats if name.startswith('Implement '))
for build in builds:
    switches.append(('left', at(f'Implement {build}')))
    switches.append(('right', at(f'Test {build}')))
    following = at(f'Implement {build + 1}') if build + 1 in builds else duration
    statuses['implement'].append((f'Build {build}', at(f'Implement {build}'), following))
    result = next(name for name in beats if name.startswith(f'Result {build} '))
    passed = int(result.split()[2])
    statuses['test'].append((f'Testing build {build}…', at(f'Test {build}'), at(result), ''))
    # The result stays on the E2E sign while Claude fixes it, until the next run.
    statuses['test'].append((f'Build {build} · {passed}/6 passed', at(result), at(f'Test {build + 1}') if build + 1 in builds else duration,
                             'pass' if passed == 6 else 'fail'))
switches[0] = ('left', 0.0)

subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{start:.3f}', '-i', str(take / 'footage.mp4'), '-t', f'{duration:.3f}',
                '-vf', f'scale={WIDTH}:{HEIGHT}:flags=lanczos', '-r', str(FPS), '-an', '-c:v', 'libx264', '-preset', 'slow',
                '-crf', '16', '-g', str(FPS), '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(HERE / 'assets/footage.mp4')],
               check=True)


def spotlight(id, region):
    x, y, w, h = region
    cx, cy, rx, ry = x + w / 2, y + h / 2, w * .74, h * .74
    gradient = (f'radial-gradient(ellipse {rx:.0f}px {ry:.0f}px at {cx:.0f}px {cy:.0f}px, rgba(8,10,14,0) 0%, '
                f'rgba(8,10,14,0) 58%, rgba(8,10,14,.68) 100%)')
    return f'<div id="{id}" class="dim" style="background:{gradient}"></div>'


def sign(id, label, region, color, lines):
    # Below the panes: the tab bar leaves no room above Codex's Chromium.
    x, y, _, h = region
    y = y + h + 104
    spans = '\n      '.join(
        f'<span id="{id}-status-{i}" class="clip status {kind}" data-start="{s:.3f}" data-duration="{e - s:.3f}" data-track-index="{3 + (id == "test")}">{text}</span>'
        for i, (text, s, e, *rest) in enumerate(lines) for kind in [rest[0] if rest else ''])
    return f'''<div id="{id}" class="sign" style="left:{x:.0f}px;top:{y - 86:.0f}px;--accent:{color}">
      <span class="label">{label}</span>
      {spans}
    </div>'''


timeline = []
for (side, t), previous in zip(switches[1:], switches):
    if side != previous[0]:
        lit, dark = ('#dim-left', '#dim-right') if side == 'left' else ('#dim-right', '#dim-left')
        signs = ('#implement', '#test') if side == 'left' else ('#test', '#implement')
        timeline.append(f'tl.to("{lit}", {{opacity: 1, duration: {FADE}, ease: "power2.inOut"}}, {max(t - FADE / 2, 0):.3f});')
        timeline.append(f'tl.to("{dark}", {{opacity: 0, duration: {FADE}, ease: "power2.inOut"}}, {max(t - FADE / 2, 0):.3f});')
        timeline.append(f'tl.to("{signs[0]}", {{opacity: 1, duration: {FADE}, ease: "power2.inOut"}}, {max(t - FADE / 2, 0):.3f});')
        timeline.append(f'tl.to("{signs[1]}", {{opacity: .4, duration: {FADE}, ease: "power2.inOut"}}, {max(t - FADE / 2, 0):.3f});')
# The loop seam is fully lit: Claude's spotlight fades in at the start and
# every dim fades out over the last moment, so the end meets the beginning.
timeline.insert(0, f'tl.fromTo("#dim-left", {{opacity: 0}}, {{opacity: 1, duration: {FADE}, ease: "power2.inOut"}}, 0);')
timeline.insert(1, f'tl.fromTo("#test", {{opacity: 1}}, {{opacity: .4, duration: {FADE}, ease: "power2.inOut"}}, 0);')
end = duration - FADE - .02
for selector in ['#dim-left', '#dim-right']:
    timeline.append(f'tl.to("{selector}", {{opacity: 0, duration: {FADE}, ease: "power2.inOut"}}, {end:.3f});')
for selector in ['#implement', '#test']:
    timeline.append(f'tl.to("{selector}", {{opacity: 1, duration: {FADE}, ease: "power2.inOut"}}, {end:.3f});')

left_controls, top_controls, diameter, gap = (v * scale for v in CONTROLS)
controls = '\n    '.join(
    f'<span class="control" style="left:{left_controls + i * (diameter + gap):.1f}px;top:{top_controls:.1f}px;'
    f'width:{diameter:.1f}px;height:{diameter:.1f}px;background:{color}"></span>' for i, color in enumerate(CONTROL_COLORS))

(HERE / 'compositions').mkdir(exist_ok=True)
(HERE / 'compositions/loop.html').write_text(f'''<template>
  <style>
    #root {{ position: absolute; inset: 0; }}
    .dim {{ position: absolute; inset: 0; opacity: 0; }}
    .control {{ position: absolute; border-radius: 50%; box-shadow: inset 0 0 0 1px rgba(0,0,0,.19); }}
    .sign {{ position: absolute; display: flex; align-items: center; gap: 14px; font-family: Inter, sans-serif; }}
    .sign .label {{ padding: 9px 18px; border-radius: 999px; background: var(--accent); color: #fff;
      font-size: 36px; font-weight: 700; letter-spacing: .01em; box-shadow: 0 8px 24px rgba(0,0,0,.35); }}
    .sign .status {{ color: #e9ebef; font-size: 32px; font-weight: 400; text-shadow: 0 2px 10px rgba(0,0,0,.6); }}
    .sign .status.fail {{ color: #ffb4a8; }}
    .sign .status.pass {{ color: #9be3a8; font-weight: 700; }}
  </style>
  <div id="root" data-composition-id="loop" data-width="{WIDTH}" data-height="{HEIGHT}" data-layout-allow-overlap>
    {spotlight('dim-left', claude)}
    {spotlight('dim-right', right)}
    {controls}
    {sign('implement', 'Implement', claude, '#c96442', statuses['implement'])}
    {sign('test', 'E2E Test', right, '#2f6fd6', statuses['test'])}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true }});
    {chr(10).join('    ' + line for line in timeline).strip()}
    tl.set({{}}, {{}}, {duration});
    window.__timelines["loop"] = tl;
  </script>
</template>
''')
(HERE / 'index.html').write_text(f'''<!doctype html>
<html>
  <head>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{duration}" data-width="{WIDTH}" data-height="{HEIGHT}">
      <video id="footage" class="clip" src="assets/footage.mp4" muted data-start="0" data-duration="{duration}"
        data-track-index="0" style="position:absolute;inset:0;width:100%;height:100%"></video>
      <div id="loop" data-composition-id="loop" data-composition-src="compositions/loop.html" data-start="0"
        data-duration="{duration}" data-track-index="1" data-track-kind="graphics" data-width="{WIDTH}" data-height="{HEIGHT}"></div>
    </div>
    <script>
      window.__timelines["main"] = gsap.timeline({{ paused: true }});
    </script>
  </body>
</html>
''')
print(f'{duration:.2f} s from {start:.2f} s of {take.name}; {len(builds)} builds')
