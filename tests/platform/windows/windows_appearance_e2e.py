"""Run one isolated Appearance case, then verify its actual rendered pixels."""
import argparse
from pathlib import Path
import subprocess
import sys
from windows_appearance_pixels import compare

ROOT=Path(__file__).resolve().parents[3]

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['details','palette'],required=True)
    parser.add_argument('--evidence',type=Path,required=True)
    parser.add_argument('--project',type=Path,default=ROOT/'frontends/godot/project')
    args=parser.parse_args()
    result=subprocess.run([sys.executable,'-X','utf8',str(ROOT/'tests/platform/windows/windows_private_replay.py'),
        '--project',str(args.project),'--evidence',str(args.evidence),
        '--replay',str(ROOT/f'tests/llm-e2e/suites/godot/integration/replays/appearance-{args.mode}.gd')])
    if result.returncode: sys.exit(result.returncode)
    sys.exit(compare(args.evidence,args.mode)['status']!='PASS')
