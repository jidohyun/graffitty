#!/usr/bin/env python3
"""Stream a reproducible sample from the Aalto ZIP once; plan from the small model thereafter."""
import argparse
import collections
import csv
import hashlib
import io
import itertools
import json
import math
from pathlib import Path
import random
import re
import statistics
import zipfile

HERE = Path(__file__).resolve().parent
WORDS = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
SEED = 136_000_000
SOURCE = 'https://userinterfaces.aalto.fi/136Mkeystrokes/'


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def key_class(a, b):
    if a.isspace(): return 'after_space'
    if b.isspace(): return 'before_space'
    if b.isupper() and a.islower(): return 'shift'
    if not a.isalpha() or not b.isalpha(): return 'symbol'
    rows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
    positions = {c: (x + y * .25, y) for y, row in enumerate(rows) for x, c in enumerate(row)}
    pa, pb = positions.get(a.lower()), positions.get(b.lower())
    if not pa or not pb: return 'symbol'
    if (pa[0] < 4.5) != (pb[0] < 4.5): return 'alternate_hands'
    return 'same_hand_near' if math.dist(pa, pb) <= 2 else 'same_hand_far'


class Reservoir:
    def __init__(self, rng, limit):
        self.rng, self.limit = rng, limit
        self.samples, self.counts = {}, collections.Counter()

    def add(self, key, value):
        self.counts[key] += 1
        values = self.samples.setdefault(key, [])
        if len(values) < self.limit: values.append(value)
        else:
            index = self.rng.randrange(self.counts[key])
            if index < self.limit: values[index] = value


def extract(archive, phrases, output, max_files=12000, max_sections=30000):
    rng = random.Random(SEED)
    wanted_words = {m[0].lower() for texts in phrases.values() for text in texts for m in WORDS.finditer(text)}
    pairs, classes, words = Reservoir(rng, 256), Reservoir(rng, 512), Reservoir(rng, 64)
    stats = collections.Counter()
    with zipfile.ZipFile(archive) as z:
        # Keep the publisher's attribution/licence locally beside the compressed source.
        for name in z.namelist():
            if name.lower().endswith('readme.txt'):
                (archive.parent / 'AALTO-README.txt').write_bytes(z.read(name))
        names = sorted(n for n in z.namelist() if n.endswith('_keystrokes.txt'))
        rng.shuffle(names)
        for name in names[:max_files]:
            stats['files_read'] += 1
            with z.open(name) as f:
                rows = csv.DictReader(io.TextIOWrapper(f, encoding='utf-8-sig', errors='replace'), delimiter='\t', quoting=csv.QUOTE_NONE)
                for _, group in itertools.groupby(rows, lambda r: r['TEST_SECTION_ID']):
                    section = list(group)
                    stats['sections_seen'] += 1
                    events = []
                    for row in section:
                        letter = row.get('LETTER') or ''
                        if letter in ('SHIFT', 'CAPS_LOCK', 'CAPSLOCK'): continue
                        if len(letter) != 1: break  # Exclude corrections/control keys, not their pause.
                        try: events.append((letter, int(row['PRESS_TIME'])))
                        except (ValueError, TypeError): break
                    else:
                        text = ''.join(e[0] for e in events)
                        if len(events) < 12 or text != section[0]['USER_INPUT'] or text != section[0]['SENTENCE']: continue
                        times = [e[1] for e in events]
                        gaps = [b - a for a, b in itertools.pairwise(times)]
                        if any(g <= 0 or g > 1500 for g in gaps): continue
                        wpm = (len(text) - 1) * 12000 / (times[-1] - times[0])
                        if not 60 <= wpm <= 145: continue
                        stats['clean_sections'] += 1
                        stats['keystrokes'] += len(events)
                        for i, gap in enumerate(gaps):
                            if not 15 <= gap <= 800: continue
                            a, b = text[i:i+2]
                            pairs.add((a+b).lower(), gap)
                            classes.add(key_class(a, b), gap)
                            classes.add('all', gap)
                        for match in WORDS.finditer(text):
                            word = match[0].lower()
                            if word not in wanted_words or len(word) < 2: continue
                            trace = gaps[match.start():match.end()-1]
                            if all(15 <= g <= 650 for g in trace): words.add(word, trace)
            if stats['files_read'] % 500 == 0: print(dict(stats), flush=True)
            if stats['clean_sections'] >= max_sections: break
    if stats['clean_sections'] < 1000: raise RuntimeError(f'Insufficient clean timing samples: {stats}')
    with archive.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
    model = {'source': SOURCE, 'archive_sha256': digest, 'seed': SEED,
             'selection': 'Correct, unedited sentence transcription; 60–145 WPM; positive press-to-press intervals. No participant IDs retained.',
             'stats': dict(stats), 'pair_counts': dict(pairs.counts), 'pairs_ms': pairs.samples,
             'classes_ms': classes.samples, 'word_traces_ms': words.samples}
    save(output, model)
    print(f'Model: {output.stat().st_size:,} bytes; {len(words.samples)} demo words, {len(pairs.samples)} letter pairs', flush=True)


def schedule(text, profile, model, variant):
    rng = random.Random(f'{SEED}:{profile}:{text}:{variant}')
    gaps = [0.0] * len(text)
    sources = collections.Counter()
    covered = set()
    # Whole-word samples preserve real correlations between consecutive keys.
    for match in WORDS.finditer(text):
        traces = model['word_traces_ms'].get(match[0].lower(), [])
        if not traces: continue
        trace = rng.choice(traces)
        pace = rng.uniform(.90, 1.08)
        for i, value in enumerate(trace, match.start() + 1):
            gaps[i] = value * pace
            covered.add(i)
            sources['word'] += 1
    quantile = rng.random()
    for i in range(1, len(text)):
        if i in covered: continue
        pair = text[i-1:i+1].lower()
        values = model['pairs_ms'].get(pair, [])
        source = 'pair'
        if len(values) < 8:
            values = model['classes_ms'].get(key_class(text[i-1], text[i]), model['classes_ms']['all'])
            source = 'keyboard_class'
        # Correlated percentile gives short bursts instead of independent jitter.
        quantile = .55 * quantile + .45 * rng.random()
        ordered = sorted(values)
        gaps[i] = ordered[min(len(ordered)-1, int(quantile * len(ordered)))]
        sources[source] += 1
    # Keep experienced demo pacing while preserving each empirical word's rhythm.
    scale = .72 if profile == 'command' else .88
    frames = [0] + [max(2, min(30, round(g * scale * 60 / 1000))) for g in gaps[1:]] if text else []
    return {'frames_before': frames, 'sources': dict(sources)}


def plan(model, phrases, output):
    result = {'fps': 60, 'source': SOURCE, 'archive_sha256': model['archive_sha256'], 'seed': SEED, 'phrases': {}}
    for profile, texts in phrases.items():
        for text in texts:
            if text in result['phrases']: raise ValueError(f'Duplicate phrase: {text}')
            variants = [schedule(text, profile, model, variant) for variant in range(4)]
            result['phrases'][text] = {'profile': profile, 'variants': variants}
    save(output, result)
    print(f'Planned {len(result["phrases"])} phrases, four fixed variants each: {output.stat().st_size:,} bytes')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--archive', type=Path, help='Read ZIP only when explicitly rebuilding the empirical model')
    p.add_argument('--model', type=Path, default=HERE/'model.json')
    p.add_argument('--phrases', type=Path, default=HERE/'phrases.json')
    p.add_argument('--output', type=Path, default=HERE/'timings.json')
    args = p.parse_args()
    phrases = json.loads(args.phrases.read_text(encoding='utf-8'))
    if args.archive: extract(args.archive, phrases, args.model)
    plan(json.loads(args.model.read_text(encoding='utf-8')), phrases, args.output)


if __name__ == '__main__': main()
