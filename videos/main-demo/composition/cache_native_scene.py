#!/usr/bin/env python3
"""Reuse the expensive native-window render independently of titles and edits."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def signature(take):
    meta = json.loads((take/'capture.json').read_text())
    # An assembled desktop retains the original source for the Chromium span.
    if meta.get('reused_recordings'):
        take = REPO / meta['reused_recordings'][-1]['source']
        meta = json.loads((take/'capture.json').read_text())
    spec = {'native':meta['native_window'], 'sources':{
        name:sha(take/name) for name in ['footage.mp4','native-window.mp4','native-window-shape.png']},
        'renderer':{name:sha(ROOT/name) for name in ['prepare_native_scene.py','native_window.py','package.json']}}
    # Head styles affect the frame, while titles/captions/shortcut timings do not.
    head = (ROOT/'index.html').read_text().split('</head>')[0]
    head = re.sub(r'<title>.*?</title>', '', head, flags=re.S)
    head = re.sub(r'@font-face\s*\{[^}]*\}', '', head)
    head = re.sub(r'\.(?:chapter-title|voice-subtitle)[^{]*\{[^}]*\}', '', head)
    spec['head'] = hashlib.sha256(head.encode()).hexdigest()
    return take, spec


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('take',type=Path)
    p.add_argument('--adopt',type=Path,help='Cache an already verified render of these inputs')
    a=p.parse_args()
    take,spec=signature(a.take.resolve())
    cache=ROOT.parent/'assets/cache/native-scene';cache.mkdir(parents=True,exist_ok=True)
    key=hashlib.sha256(json.dumps(spec,sort_keys=True).encode()).hexdigest()[:20]
    target=cache/(key+'.mp4')
    artifact=REPO/'videos/artifacts/main-demo/native-chromium-scene.mp4'
    if not target.exists():
        if not a.adopt:
            subprocess.run(['python3',str(ROOT/'prepare_native_scene.py'),str(take)],check=True)
            subprocess.run(['bun','run','check'],cwd=ROOT/'native-scene',check=True)
            subprocess.run(['python3',str(REPO/'videos/shared/render.py'),'--project',str(ROOT/'native-scene'),'--output',str(artifact),'--fps','60','--quality','delivery'],check=True)
        shutil.copy2(a.adopt or artifact,target)
        (cache/(key+'.json')).write_text(json.dumps(spec,indent=2)+'\n')
        print('Cached native scene:',target)
    else:
        print('Reusing native scene:',target)
    if artifact.resolve()!=target.resolve(): shutil.copy2(target,artifact)

if __name__=='__main__': main()
