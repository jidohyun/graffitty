"""Feathered ellipse adapted from the registry's yt-feather-highlight.

Keep the two ownership links clear while dimming the surrounding app footage.
The same frozen mask and linear fades are used by HTML and FFmpeg.
"""
import json
from io import BytesIO
from pathlib import Path
import re
from PIL import Image, ImageDraw

FADE = 1.1
ASSET = 'assets/connecting-line-spotlight.png'


def timings(root):
    # Preserve the approved effect relative to the frozen ownership narration,
    # even when an earlier recording or session transition changes film duration.
    cue = next(c for c in json.loads((root/'demo-narration-cues.json').read_text())['cues']
               if c['id'] == 'chromium-ownership')
    start = cue['start'] + 13.933333333333334
    out = cue['start'] + 17.4
    return start, out, out + FADE


def mask(root):
    width, height = 1344, 840
    image = Image.new('RGBA', (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            radius = (((x-672)/560)**2 + ((y-488)/330)**2)**.5
            alpha = round(255 * .45 * min(1, max(0, (radius-.52)/.36)))
            pixels[x,y] = (6, 8, 12, alpha)
    # Match the existing window's rounded silhouette.
    corners = Image.new('L', (width,height));ImageDraw.Draw(corners).rounded_rectangle((0,0,width-1,height-1),radius=20,fill=255)
    from PIL import ImageChops
    image.putalpha(ImageChops.multiply(image.getchannel('A'), corners))
    encoded = BytesIO()
    image.save(encoded, format='PNG')
    path = root / ASSET
    data = encoded.getvalue()
    # Appending later chapters must not invalidate a rendered desktop when
    # its shared mask's pixels have not changed.
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def apply(root):
    START, OUT, END = timings(root)
    mask(root)
    path=root/'index.html';source=path.read_text()
    source=re.sub(r'\s*<!-- connecting-line-spotlight:start -->.*?<!-- connecting-line-spotlight:end -->','',source,flags=re.S)
    source=re.sub(r'\s*// connecting-line-spotlight:start.*?// connecting-line-spotlight:end','',source,flags=re.S)
    block=f'''    <!-- connecting-line-spotlight:start -->
    <img id="connecting-line-spotlight" class="clip" src="{ASSET}" data-start="{START}" data-duration="{END-START}" data-track-index="9" style="position:absolute;left:288px;top:112px;width:1344px;height:840px;z-index:8;pointer-events:none;opacity:0" alt="">
    <!-- connecting-line-spotlight:end -->'''
    source=source.replace('    <!-- subtitles:end -->','    <!-- subtitles:end -->\n'+block)
    script=f'''\n    // connecting-line-spotlight:start
    window.__timelines["main"].fromTo("#connecting-line-spotlight", {{opacity:0}}, {{opacity:1,duration:{FADE},ease:"none"}}, {START});
    window.__timelines["main"].to("#connecting-line-spotlight", {{opacity:0,duration:{FADE},ease:"none"}}, {OUT});
    // connecting-line-spotlight:end'''
    source=source.replace('gsap.timeline({ paused: true });','gsap.timeline({ paused: true });'+script)
    path.write_text(source)
    (root/'spotlight.json').write_text(json.dumps(dict(start=START,fade=FADE,fade_out=OUT,end=END,center=[960,600],radii=[560,330],dim=.45,registry='yt-feather-highlight'),indent=2)+'\n')


def render_inputs(root, first_input, previous, offset=0):
    START, OUT, END = timings(root)
    inputs=['-loop','1','-framerate','60','-i',str(root/ASSET)]
    filters=[f'[{first_input}:v]format=rgba,fade=t=in:st={START-offset}:d={FADE}:alpha=1,fade=t=out:st={OUT-offset}:d={FADE}:alpha=1[spotlight-mask]',
             f"[{previous}][spotlight-mask]overlay=288:112:enable='gte(t,{START-offset})*lt(t,{END-offset})':eof_action=pass[spotlight-film]"]
    return inputs,filters,'spotlight-film'

if __name__=='__main__':apply(Path(__file__).resolve().parent)
