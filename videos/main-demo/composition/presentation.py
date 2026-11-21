"""Shared chapter titles and voice-timed subtitles for Studio and deliveries."""
from difflib import SequenceMatcher
import html
import json
from pathlib import Path
import re
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import shortcuts
import payload_underlines

TITLE_ACCENT = '#b8d8f8'
TEXT_COLOR = '#f1f2f4'


def title_parts(text):
    label, separator, description = text.partition(':')
    return label + separator, description


def colored_title(text):
    label, description = title_parts(text)
    return (f'<span style="display:inline;color:{TITLE_ACCENT}">{html.escape(label)}</span>'
            + html.escape(description))


PHRASES = {
    "watcher-intro": ["This makes your graph pipeline versatile.", "For example, create a simple watcher node", "that triggers your agent when a condition is met."],
    "watcher-connect": ["Connect the watcher to Claude."],
    "watcher-result": ["A new email arrives,", "and Claude makes a podcast just as it's told to!"],
    "protocol-inspector": ["You can even make your own custom node", "very easily with Graffitty Graph Protocol.", "First, let's use the Payload Inspector node,", "which shows what data are sent through the graph."],
    "protocol-payload": ["It sends just enough information", "for the next node to process,", "like the session file path and the last message."],
    "protocol-code": ["Here is a minimal Python example", "that uses the GGP protocol", "to convert the data to uppercase."],
    "protocol-ports": ["Define the input and output ports,", "process the data, and send it on."],
    "protocol-run": ["Run it."],
    "protocol-connect": ["Connect the nodes,"],
    "protocol-send": ["Send the message."],
    "protocol-result": ["This node converts the message to uppercase.", "The Payload Inspector shows the result.", "That's it."],
    "android-intro": ["Just like tmux keeps your session alive", "on an SSH server,", "you can detach from Graffitty", "and attach again any time.", "It even has mobile clients,", "so you can code wherever you are."],
    "android-workspace": ["Let me explain how the graph feature works.", "Each terminal pane can advertise itself as a node,", "so it can queue messages to another pane."],
    "android-wiring": ["For example, Codex on the left implements a feature", "and sends its work to Claude in the middle."],
    "android-review": ["Claude only sends to the Slack node", "when a condition is met", "that the user needs to know about."],
    "android-implement": ["Now ask Codex to implement the website."],
    "android-handoff": ["When Codex finishes,", "Claude receives its session and checks the work."],
    "android-slack": ["Claude finds missing requirements", "and sends the review to Slack."],
    "parallel-intro": ["The parallel node waits", "until every agent finishes."],
    "parallel-combined": ["Once all three finish,", "it sends their results and session references", "together to the reviewer."],
    "systemone-intro": ["Graph is very useful when you want", "to quickly prototype a pipeline.", "This SystemOne node that calls", "the JEV decision model in the middle", "will route the session for you", "based on your question!"],
    "intro": ["Graffitty is a terminal emulator,", "with a tiling manager and Chromium."],
    "workspace-space": ["But if you zoom out, you'll notice", "there's much more space to work with."],
    "workspace-status": ["Each pane shows CPU, RAM usage,", "and agent status."],
    "workspace-stash": ["Stash a pane outside the main view."],
    "chromium-automation": ["Multiple agents can each use", "an isolated Chromium session,", "so they can run end-to-end tests in parallel."],
    "workspace-main": ["You can return to the main view at any time."],
    "workspace-pane": ["Or jump back to your previous view", "and take a closer look at any pane."],
    "filetree-cwd": ["The builtin filetree is synchronised", "with the shell's current working directory."],
    "filetree-rename": ["You can edit the file name like editing a vim buffer,", "and save to apply it."],
    "filetree-open": ["Opening the files opens Neovim,", "or Chromium to preview all kinds of media."],
    "filetree-send-path": ["You can also send file paths to the terminal,", "allowing you to change directory or open files."],
    "chromium-markdown": ["Get creative with Chromium.", "It's a versatile viewer that handles things", "traditional terminals often need workarounds for.", "For example, use the MarkdownPreview plugin", "in Neovim to open Graffitty Chromium.", "Now you have a live Markdown preview", "right inside your terminal."],
    "chromium-diagram": ["Ask Claude to explain with a diagram.", "Graffitty Chromium will open right beside your terminal."],
    "tabs-summary": ["The down arrow gives you a summary of every tab,", "including its panes, CPU and RAM usage,", "and agent status.", "Type to fuzzy search tab and pane titles."],
    "command-line": ["Aren't you already used to Vim's command line?", "The same thing is here,", "with a fuzzy finder built in.", "You no longer have to keep", "every terminal feature as a key map.", "Search commands, switch tabs, or jump to a pane."],
    "chromium-native": ["You can also use Chromium's native interface", "in a separate window.", "Closing that window doesn't close Chromium.", "It simply brings the same chromium back into Graffitty."],
    "chromium-ownership": ["One thing I find frustrating about agentic coding", "is how quickly agents can open a jumble of windows.", "They get in the way, steal focus,", "and make it hard to tell which agent is using which browser.", "That's why Graffitty shows clear ownership", "with a connecting line.", "You can move chromiums out of the main view", "and still see who's using them."],
}


def normalize(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def subtitles(root):
    voices = {v["id"]: v for v in json.loads((root / "demo-audio.json").read_text())["voices"]}
    scripts = {v["id"]: v["text"] for v in json.loads((root / "demo-narration.json").read_text())["lines"]}
    placed = json.loads((root / "demo-narration-cues.json").read_text())["cues"]
    result = []
    for cue in placed:
        phrases = PHRASES[cue["id"]]
        script = normalize(" ".join(phrases))
        assert script == normalize(scripts[cue["id"]]), "Caption phrases must preserve the spoken script"
        words = voices[cue["id"]]["words"]
        transcript = "".join(normalize(w["text"]) for w in words)
        owner = [i for i, word in enumerate(words) for _ in normalize(word["text"])]
        match = SequenceMatcher(None, script, transcript, autojunk=False)
        assert match.ratio() > .94, "Transcript needs manual alignment"
        mapping = {a + j: owner[b + j] for a, b, n in match.get_matching_blocks() for j in range(n)}
        cursor = 0
        local = []
        for phrase in phrases:
            stop = cursor + len(normalize(phrase))
            indexes = [mapping[i] for i in range(cursor, stop) if i in mapping]
            assert indexes
            local.append({"voice": cue["id"], "text": phrase,
                          "start": round((cue["start"] + words[min(indexes)]["start"]) * 60) / 60,
                          "end": min(cue["end"], round((cue["start"] + words[max(indexes)]["end"] + .12) * 60) / 60)})
            cursor = stop
        for i, line in enumerate(local[:-1]):
            line["end"] = min(line["end"], local[i + 1]["start"])
        result.extend(local)
    for i, line in enumerate(result):
        assert line["end"] > line["start"]
        assert i == 0 or result[i - 1]["end"] <= line["start"]
    return result


def title_html(chapters):
    return "\n".join(
        f'    <div id="chapter-title-{i}" class="clip chapter-title" data-start="{c["start"]:.6f}" '
        f'data-duration="{c["duration"]:.6f}" data-track-index="2" data-track-kind="overlay">'
        f'<span id="chapter-title-text-{i}">{colored_title(c["text"])}</span></div>'
        for i, c in enumerate(chapters))


def title_animation(chapters):
    lines = ['    // chapter-titles-stage:start']
    for i, c in enumerate(chapters):
        target = f'#chapter-title-text-{i}'
        lines.append(f'    window.__timelines["main"].fromTo("{target}", {{opacity:0,y:4}}, '
                     f'{{opacity:1,y:0,duration:.28,ease:"none",immediateRender:false}}, {c["start"]:.6f});')
        lines.append(f'    window.__timelines["main"].to("{target}", {{opacity:0,duration:.18,ease:"none"}}, '
                     f'{c["start"] + c["duration"] - .18:.6f});')
    return "\n".join(lines + ['    // chapter-titles-stage:end'])


def ass_time(seconds):
    cs = round(seconds * 100)
    return f'{cs // 360000}:{cs // 6000 % 60:02}:{cs // 100 % 60:02}.{cs % 100:02}'


def write_ass(path, chapters, captions):
    header = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Title,Open Sans SemiBold,40,&H00F4F2F1,&H00F4F2F1,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,100,100,0,1
Style: Voice,Open Sans SemiBold,34,&H00F4F2F1,&H00F4F2F1,&H80000000,&H80000000,0,0,0,0,100,100,0,0,1,0,1,5,100,100,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''
    lines = [header]
    for c in chapters:
        label, description = title_parts(c['text'])
        accent_bgr = ''.join(reversed([TITLE_ACCENT[i:i+2] for i in (1, 3, 5)])).upper()
        text = f'{{\\c&H{accent_bgr}&}}{label}{{\\c&HF4F2F1&}}{description}'
        lines.append(f'Dialogue: 0,{ass_time(c["start"])},{ass_time(c["start"]+c["duration"])},Title,,0,0,0,,{{\\fad(280,180)\\move(960,66,960,62,0,280)}}{text}\n')
    for c in captions:
        lines.append(f'Dialogue: 1,{ass_time(c["start"])},{ass_time(c["end"])},Voice,,0,0,0,,{{\\pos(960,1008)}}{c["text"]}\n')
    path.write_text("".join(lines))


def apply(root):
    desktop = json.loads((root / 'capture.json').read_text())
    android = json.loads((root / 'android-capture.json').read_text())
    chapters = desktop['chapters'] + android['chapters']
    # The graph chapters follow Android in this order: SystemOne, Parallel,
    # Graph Protocol, then Watcher.
    for name in ['systemone', 'parallel', 'protocol', 'watcher']:
        node = json.loads((root / f'{name}-capture.json').read_text())
        chapters.append({'start': node['start'], 'duration': node['duration'], 'text': node['subtitle']})
    # Chapter labels and descriptions use consistent sentence case.
    chapters = [{**c, 'text': ': '.join(part.strip()[:1].upper() + part.strip()[1:] for part in c['text'].split(':'))} for c in chapters]
    captions = subtitles(root)
    key_cues = shortcuts.cues(root, desktop)
    key_html, key_script = shortcuts.compose(key_cues)
    source = (root / 'index.html').read_text()
    source = source.replace('padding-top: 56px', 'padding-top: 112px')
    source = source.replace('left:288px;top:56px', 'left:288px;top:112px')
    source = re.sub(r'    \.subtitles \{.*?\n    \}', '''    .chapter-title {
      position:absolute;left:100px;top:34px;width:1720px;height:56px;margin:0;z-index:10;
      display:flex;align-items:center;justify-content:center;text-align:center;
      font-family:"Demo Open Sans",sans-serif;font-weight:600;font-size:40px;line-height:1.2;
    }
    .chapter-title span { display:block; }
    .voice-subtitle {
      position:absolute;left:192px;top:978px;width:1536px;height:60px;margin:0;z-index:10;
      display:flex;align-items:center;justify-content:center;text-align:center;
      font-family:"Demo Open Sans",sans-serif;font-weight:600;font-size:34px;line-height:1.2;
      text-shadow:0 1px 2px #0008;
    }''', source, flags=re.S)
    source = re.sub(r'<!-- subtitles:start -->.*?<!-- subtitles:end -->',
                    '<!-- subtitles:start -->\n' + title_html(chapters) + '\n    <!-- subtitles:end -->', source, flags=re.S)
    source = source.replace('height:56px;margin:0;\n', 'height:56px;margin:0;z-index:10;\n')
    source = source.replace('height:60px;margin:0;\n', 'height:60px;margin:0;z-index:10;\n')
    source = re.sub(r'\s*<p id="parallel-subtitle".*?</p>', '', source, flags=re.S)
    source = re.sub(r'\s*<!-- voice-subtitles:start -->.*?<!-- voice-subtitles:end -->', '', source, flags=re.S)
    subtitles_html = '\n'.join(f'    <p id="voice-subtitle-{i}" class="clip voice-subtitle" '
        f'data-start="{c["start"]:.6f}" data-duration="{c["end"]-c["start"]:.6f}" '
        f'data-track-index="6" data-track-kind="captions">{html.escape(c["text"])}</p>' for i, c in enumerate(captions))
    source = source.replace('    <!-- subtitles:end -->', '    <!-- subtitles:end -->\n'
        '    <!-- voice-subtitles:start -->\n' + subtitles_html + '\n    <!-- voice-subtitles:end -->')
    source = re.sub(r'\s*// chapter-titles-stage:start.*?// chapter-titles-stage:end', '', source, flags=re.S)
    source = re.sub(r'\s*<!-- shortcut-keys:start -->.*?<!-- shortcut-keys:end -->', '', source, flags=re.S)
    source = re.sub(r'\s*// shortcut-keys-stage:start.*?// shortcut-keys-stage:end', '', source, flags=re.S)
    source = source.replace('    <!-- subtitles:end -->', '    <!-- subtitles:end -->\n' + key_html)
    source = source.replace('gsap.timeline({ paused: true });', 'gsap.timeline({ paused: true });\n' + title_animation(chapters))
    source = source.replace('gsap.timeline({ paused: true });', 'gsap.timeline({ paused: true });\n' + key_script)
    underline_cues = payload_underlines.cues(root)
    payload_underlines.render_assets(root, underline_cues)
    source = re.sub(r'\s*<!-- payload-underlines:start -->.*?<!-- payload-underlines:end -->', '', source, flags=re.S)
    source = source.replace('    <!-- subtitles:end -->', '    <!-- subtitles:end -->\n' + payload_underlines.html(underline_cues))
    (root / 'index.html').write_text(source)
    from music import apply as apply_music
    apply_music(root)
    from spotlight import apply as apply_spotlight
    apply_spotlight(root)
    (root / 'presentation.json').write_text(json.dumps({'chapters': chapters, 'subtitles': captions,
        'window_y': 112, 'title_center_y': 62, 'subtitle_center_y': 1008,
        'title_label_color': TITLE_ACCENT, 'text_color': TEXT_COLOR,
        'shortcuts': key_cues, 'underlines': underline_cues}, indent=2) + '\n')
    write_ass(root / 'presentation.ass', chapters, captions)
    srt, vtt = subtitle_files(captions)
    (root / 'demo-subtitles.srt').write_text(srt)
    (root / 'demo-subtitles.vtt').write_text(vtt)
    print(f'Prepared {len(chapters)} chapter titles and {len(captions)} voice-timed subtitles')


def subtitle_files(captions):
    """SRT and WebVTT text for timed captions."""
    def srt_time(t):
        ms = round(t * 1000)
        return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
    srt = '\n\n'.join(f'{i+1}\n{srt_time(c["start"])} --> {srt_time(c["end"])}\n{c["text"]}' for i,c in enumerate(captions)) + '\n'
    return srt, 'WEBVTT\n\n' + re.sub(r'(\d{2}:\d{2}:\d{2}),(\d{3})', r'\1.\2', srt)


def render_inputs(root, first_input=3, offset=0, duration=None, allow_tail_overlap=False, voice_ids=None):
    """Rasterize the same frozen font; keep FFmpeg independent of libass builds."""
    data = json.loads((root / 'presentation.json').read_text())
    if voice_ids is not None:
        # Add new captions over a reused, already-composited scene without
        # drawing its existing title, shortcuts, or captions a second time.
        data['chapters'], data['shortcuts'] = [], []
        data['underlines'] = []
        data['subtitles'] = [cue for cue in data['subtitles'] if cue['voice'] in voice_ids]
    if offset or duration is not None:
        end = offset + duration if duration is not None else float('inf')
        for kind in ['chapters', 'subtitles', 'shortcuts', 'underlines']:
            selected = []
            for cue in data.get(kind, []):
                stop = cue.get('end', cue['start'] + cue.get('duration', 0))
                # Frame-derived boundaries can differ by a few floating-point
                # bits after subtracting earlier cuts (e.g. 115.65 vs 115.6499…).
                if cue['start'] >= end - 1e-6 or stop <= offset + 1e-6:
                    continue
                assert cue['start'] >= offset - 1e-6 and (stop <= end + 1e-6 or allow_tail_overlap), 'Chapter boundary cuts a presentation cue'
                # A prefix splice may end mid-title/caption. Keep its original
                # fade and lifetime; the retained video continues the same cue.
                shifted = {**cue, 'start': max(0, cue['start'] - offset)}
                if 'end' in cue: shifted['end'] -= offset
                for key in ['start_frame', 'end_frame']:
                    if key in cue: shifted[key] -= round(offset * 60)
                selected.append(shifted)
            data[kind] = selected
    folder = root / ('.hyperframes/presentation' if not offset else '.hyperframes/presentation-systemone')
    folder.mkdir(parents=True, exist_ok=True)
    inputs, filters = [], []
    previous = 'film'
    for i, cue in enumerate(data['chapters'] + data['subtitles']):
        title = i < len(data['chapters'])
        width, height, size = (1720, 56, 40) if title else (1536, 60, 34)
        font = ImageFont.truetype(str(root / 'assets/OpenSans-Semibold.ttf'), size)
        assert font.getlength(cue['text']) < width - 20, 'Text exceeds its safe width'
        picture = Image.new('RGBA', (width, height))
        if not title:
            shadow = ImageDraw.Draw(picture)
            shadow.text((width/2, height/2+1), cue['text'], font=font, anchor='mm', fill=(0,0,0,128))
            picture = picture.filter(ImageFilter.GaussianBlur(1))
        draw = ImageDraw.Draw(picture)
        if title:
            label, description = title_parts(cue['text'])
            left = (width - font.getlength(cue['text'])) / 2
            draw.text((left, height/2), label, font=font, anchor='lm', fill=TITLE_ACCENT)
            draw.text((left + font.getlength(label), height/2), description,
                      font=font, anchor='lm', fill=TEXT_COLOR)
        else:
            draw.text((width/2, height/2), cue['text'], font=font, anchor='mm', fill=TEXT_COLOR)
        path = folder / f'{i:02}.png'
        picture.save(path)
        start = cue['start']
        end = start + cue['duration'] if title else cue['end']
        if title:
            inputs += ['-loop','1','-framerate','60','-t',str(cue['duration']),'-i',str(path)]
            filters.append(f'[{first_input+i}:v]format=rgba,fade=t=in:st=0:d=0.28:alpha=1,'
                           f'fade=t=out:st={cue["duration"]-.18}:d=0.18:alpha=1,'
                           f'setpts=PTS-STARTPTS+{start}/TB[text{i}]')
            text = f'text{i}'
            x, y = 100, f"34+4*(1-min(max((t-{start})/.28,0),1))"
        else:
            inputs += ['-i',str(path)]
            text = f'{first_input+i}:v'
            x, y = 192, '978'
        following = f'lettered{i}'
        filters.append(f"[{previous}][{text}]overlay=x={x}:y='{y}':enable='gte(t,{start})*lt(t,{end})'"
                       + (':eof_action=pass' if title else '') + f'[{following}]')
        previous = following
    key_inputs, key_filters, previous = shortcuts.render_inputs(
        root, data.get('shortcuts', []), first_input+len(data['chapters'])+len(data['subtitles']), previous)
    from spotlight import render_inputs as spotlight_inputs, timings as spotlight_timings
    light_inputs, light_filters = [], []
    light_start, _, light_end = spotlight_timings(root)
    if voice_ids is None and light_end > offset and (duration is None or light_start < offset + duration):
        light_inputs, light_filters, previous = spotlight_inputs(root, first_input+inputs.count('-i')+key_inputs.count('-i'), previous, offset)
    underline_inputs, underline_filters, previous = payload_underlines.render_inputs(
        root, data.get('underlines', []), first_input+inputs.count('-i')+key_inputs.count('-i')+light_inputs.count('-i'), previous)
    return (inputs+key_inputs+light_inputs+underline_inputs,
            ';'.join(filters+key_filters+light_filters+underline_filters), previous)


if __name__ == '__main__':
    apply(Path(__file__).resolve().parent)
