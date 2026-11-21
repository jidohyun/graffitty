#!/usr/bin/env python3
"""A 720p WebM copy of the delivered film in English or another language.
English keeps the film's own text.

Another language replaces its chapter titles and captions with
locales/<language>.json, at the same times and places. Options split the
copy at chapters and cap each file's size."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from presentation import TEXT_COLOR, TITLE_ACCENT, subtitle_files, title_parts

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / 'artifacts/main-demo'
WORK = ROOT / '.hyperframes/localized'
FILM = OUT / 'main-demo.webm'
WIDTH, HEIGHT, FPS, AUDIO = 1280, 720, 30, 96_000
QUALITY = 30  # VP9 CRF when no size cap is given
VP9 = ['-c:v', 'libvpx-vp9', '-deadline', 'good', '-row-mt', '1', '-tile-columns', '2', '-threads', '8', '-g', '240']
# Film coordinates (1920 × 1080) of the text boxes laid out by presentation.py.
TITLE, CAPTION = (100, 34, 1720, 56), (192, 978, 1536, 60)
# Each region covers the widest English line of its kind and is rebuilt row by
# row from 36-pixel strips just beyond it: the title band is flat, and under the
# captions only the window's drop shadow varies, by row.
ERASE = [((279, 42, 1362, 54), (225, 1659)), ((444, 975, 1032, 66), (402, 1482))]


def px(value):
    """A film coordinate at the output resolution."""
    return round(value * HEIGHT / 1080)


def localize(language):
    """The film's titles and captions with their timings, translated unless English."""
    presentation = json.loads((ROOT / 'presentation.json').read_text())
    titles = [dict(start=c['start'], end=c['start'] + c['duration'], text=c['text']) for c in presentation['chapters']]
    captions = [dict(start=c['start'], end=c['end'], text=c['text']) for c in presentation['subtitles']]
    if language == 'en':
        return None, titles, captions
    data = json.loads((ROOT / f'locales/{language}.json').read_text())
    assert [c['text'] for c in presentation['chapters']] == [t['en'] for t in data['titles']] and \
        [(c['voice'], c['text']) for c in presentation['subtitles']] == [(c['voice'], c['en']) for c in data['captions']], \
        f'locales/{language}.json must translate the current English titles and captions'
    for cue, translation in zip(titles + captions, data['titles'] + data['captions']):
        cue['text'] = translation['text']
    return data['font'], titles, captions


def title_image(font, text, path):
    """The film's title look: the label before the colon in the accent colour."""
    face = ImageFont.truetype(font['file'], px(font['title']), index=font['index'])
    width, height = px(TITLE[2]), px(TITLE[3])
    assert face.getlength(text) < width - 20, f'Title exceeds its safe width: {text}'
    label, description = title_parts(text)
    left = (width - face.getlength(text)) / 2
    picture = Image.new('RGBA', (width, height))
    draw = ImageDraw.Draw(picture)
    draw.text((left, height / 2), label, font=face, anchor='lm', fill=TITLE_ACCENT)
    draw.text((left + face.getlength(label), height / 2), description, font=face, anchor='lm', fill=TEXT_COLOR)
    picture.save(path)


def caption_image(font, text, path):
    """The film's caption look: centred text with a soft shadow."""
    face = ImageFont.truetype(font['file'], px(font['caption']), index=font['index'])
    width, height = px(CAPTION[2]), px(CAPTION[3])
    assert face.getlength(text) < width - 20, f'Caption exceeds its safe width: {text}'
    picture = Image.new('RGBA', (width, height))
    ImageDraw.Draw(picture).text((width / 2, height / 2 + 1), text, font=face, anchor='mm', fill=(0, 0, 0, 128))
    picture = picture.filter(ImageFilter.GaussianBlur(1))
    ImageDraw.Draw(picture).text((width / 2, height / 2), text, font=face, anchor='mm', fill=TEXT_COLOR)
    picture.save(path)


def text_graph(name, font, first, titles, captions):
    """Extra inputs and the filters that put the language's text on frames from `first`."""
    scale = f'[0:v]fps={FPS},scale={WIDTH}:{HEIGHT}:flags=lanczos'
    if font is None:
        return [], [scale + ',format=yuv420p[video]']
    offset = first / 60
    strips = ''.join(f'[l{i}][r{i}]' for i in range(len(ERASE)))
    filters = [scale + f',format=yuv444p,split={1 + 2 * len(ERASE)}[c0]{strips}']
    for i, ((x, y, width, height), (left, right)) in enumerate(ERASE):
        for side, at in [('l', left), ('r', right)]:
            filters.append(f'[{side}{i}]crop={px(36)}:{px(height)}:{px(at)}:{px(y)},scale=1:{px(height)}:flags=area[{side}{i}s]')
        filters.append(f'[l{i}s][r{i}s]hstack,scale={px(width)}:{px(height)}:flags=bilinear[patch{i}]')
        filters.append(f'[c{i}][patch{i}]overlay={px(x)}:{px(y)}[c{i + 1}]')
    inputs, previous = [], f'c{len(ERASE)}'
    rise = 4 * HEIGHT / 1080  # Titles rise 4 film pixels while fading in, as in the film.
    for i, cue in enumerate(titles):
        image = WORK / f'{name}-title-{i:02}.png'
        title_image(font, cue['text'], image)
        start, end = cue['start'] - offset, cue['end'] - offset
        index = 1 + inputs.count('-i')
        inputs += ['-loop', '1', '-framerate', str(FPS), '-t', f'{end - start:.6f}', '-i', str(image)]
        filters.append(f'[{index}:v]format=rgba,fade=t=in:st=0:d=0.28:alpha=1,'
                       f'fade=t=out:st={end - start - .18:.6f}:d=0.18:alpha=1,setpts=PTS-STARTPTS+{start:.6f}/TB[title{i}]')
        filters.append(f"[{previous}][title{i}]overlay=x={px(TITLE[0])}:"
                       f"y='{TITLE[1] * HEIGHT / 1080:.4f}+{rise:.4f}*(1-min(max((t-{start:.6f})/.28,0),1))':"
                       f"enable='gte(t,{start:.6f})*lt(t,{end:.6f})':eof_action=pass[t{i}]")
        previous = f't{i}'
    for i, cue in enumerate(captions):
        image = WORK / f'{name}-caption-{i:02}.png'
        caption_image(font, cue['text'], image)
        start, end = cue['start'] - offset, cue['end'] - offset
        index = 1 + inputs.count('-i')
        inputs += ['-i', str(image)]
        filters.append(f"[{previous}][{index}:v]overlay={px(CAPTION[0])}:{px(CAPTION[1])}:"
                       f"enable='gte(t,{start:.4f})*lt(t,{end:.4f})'[s{i}]")
        previous = f's{i}'
    return inputs, filters + [f'[{previous}]format=yuv420p[video]']


def encode(name, inputs, filters, first, last, rate, output, fade_in, fade_out):
    """Two-pass VP9 of film frames [first, last), keeping every other frame: at
    `rate` bits per second, or at constant quality when `rate` is None."""
    duration, frames = (last - first) / 60, (last - first) // 2
    # Seek a millisecond early: WebM timestamps are rounded to milliseconds.
    film = (['-ss', f'{first / 60 - .001:.6f}'] if first else []) + ['-i', str(FILM)]
    fades = (['afade=t=in:d=0.15'] if fade_in else []) + ([f'afade=t=out:st={duration - .5:.4f}:d=0.5'] if fade_out else [])
    target = ['-b:v', str(rate)] if rate else ['-crf', str(QUALITY), '-b:v', '0']
    base = ['ffmpeg', '-v', 'error', '-y', *film, *inputs, '-filter_complex', ';'.join(filters), '-map', '[video]',
            '-frames:v', str(frames), *VP9, *target, '-passlogfile', str(WORK / name)]
    subprocess.run([*base, '-cpu-used', '4', '-pass', '1', '-an', '-f', 'null', '-'], check=True)
    subprocess.run([*base, '-cpu-used', '2', '-pass', '2', '-map', '0:a', '-t', f'{duration:.6f}',
                    '-af', ','.join(fades) or 'anull', '-c:a', 'libopus', '-b:a', str(AUDIO), str(output)], check=True)


def main():
    languages = ['en'] + sorted(path.stem for path in (ROOT / 'locales').glob('*.json'))
    chapters = {c['text']: c['start'] for c in json.loads((ROOT / 'presentation.json').read_text())['chapters']}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lang', choices=languages, required=True)
    parser.add_argument('--split', action='append', default=[], metavar='CHAPTER',
                        help='start a new part at this English chapter title (repeatable)')
    parser.add_argument('--max-mb', type=float, help='keep each file under this many megabytes (10^6 bytes)')
    args = parser.parse_args()
    for title in args.split:
        if title not in chapters or not chapters[title]:
            parser.error(f'--split needs a chapter title after the first: {title!r}')
    WORK.mkdir(parents=True, exist_ok=True)
    font, titles, captions = localize(args.lang)
    if font:
        srt, vtt = subtitle_files(captions)
        (OUT / f'main-demo.{args.lang}.srt').write_text(srt)
        (OUT / f'main-demo.{args.lang}.vtt').write_text(vtt)
    total = json.loads((OUT / 'main-demo.webm.json').read_text())['frames']
    # Even cuts keep every part on the same every-other-frame sampling.
    bounds = [0, *sorted({round(chapters[title] * 60) // 2 * 2 for title in args.split}), total]
    parts = list(zip(bounds, bounds[1:]))
    for index, (first, last) in enumerate(parts, 1):
        begin, finish = first / 60, last / 60
        assert not any(c['start'] < begin < c['end'] - 1 / FPS for c in titles + captions), 'Split between titles and captions'
        part_titles = [c for c in titles if begin <= c['start'] < finish]
        part_captions = [c for c in captions if begin <= c['start'] < finish]
        name = f'{args.lang}-part{index}'
        output = OUT / (f'main-demo.{args.lang}.part{index}.webm' if len(parts) > 1 else f'main-demo.{args.lang}.webm')
        # Keep a part whose film, text, cut and size cap are unchanged.
        signature = hashlib.sha256(json.dumps([FILM.stat().st_size, FILM.stat().st_mtime_ns, str(output), font, first,
            last, part_titles, part_captions, args.max_mb, Path(__file__).read_text()]).encode()).hexdigest()
        stamp = WORK / f'{name}.signature'
        if output.exists() and stamp.exists() and stamp.read_text() == signature:
            print(f'{output.name}: unchanged', flush=True)
            continue
        inputs, filters = text_graph(name, font, first, part_titles, part_captions)
        seconds, fade_in, fade_out = finish - begin, first > 0, last < total
        rate = None
        if args.max_mb is None:
            encode(name, inputs, filters, first, last, rate, output, fade_in, fade_out)
        else:
            limit = args.max_mb * 1e6
            # Two-pass rate control lands within a few percent of its target; a
            # 4 % margin also covers the audio's variation and the WebM container.
            rate = int(limit * 8 * .96 / seconds) - AUDIO
            for _ in range(3):
                encode(name, inputs, filters, first, last, rate, output, fade_in, fade_out)
                if output.stat().st_size < limit:
                    break
                rate = int(rate * limit * .96 / output.stat().st_size)
            else:
                raise SystemExit(f'{output.name} stays above {args.max_mb} MB')
        probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_frames',
            '-show_entries', 'stream=nb_read_frames,width,height', '-of', 'json', str(output)]))['streams'][0]
        assert (probe['width'], probe['height'], int(probe['nb_read_frames'])) == (WIDTH, HEIGHT, (last - first) // 2)
        stamp.write_text(signature)
        print(f'{output.name}: {seconds:.2f}s, {len(part_titles)} titles, {len(part_captions)} captions, '
              f'{output.stat().st_size / 1e6:.2f} MB' + (f' at {rate // 1000} kb/s video' if rate else f' at CRF {QUALITY}'),
              flush=True)


if __name__ == '__main__':
    main()
