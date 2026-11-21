"""Focused Godot effect checks on a private Windows desktop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from windows_protocol_actions_e2e import ROOT, dashboard, private_station
import windows_private_desktop


def compare_pixels(directory):
    from PIL import Image, ImageChops
    comparisons = []
    peaks = sorted(directory.glob('trail-*-peak.png')) + sorted(p for p in directory.glob('particles-*.png') if not p.stem.endswith('-off'))
    assert len(peaks) == 8, 'Three trails and five particle captures required'
    for peak in peaks:
        after = peak.with_name(peak.name.replace('-peak', '-after')) if peak.stem.startswith('trail-') else peak.with_name(peak.stem + '-off.png')
        # The fixed replay viewport has a 120-pixel application/title region.
        # Compare terminal content independently of title antialiasing.
        a = Image.open(peak).convert('RGB').crop((0, 120, 1600, 1000))
        b = Image.open(after).convert('RGB').crop((0, 120, 1600, 1000))
        difference = ImageChops.difference(a, b)
        changed = sum(max(pixel) > 8 for pixel in difference.get_flattened_data())
        assert changed > 40, (peak.name, changed)
        comparisons.append({'peak':peak.name, 'after':after.name, 'changed_pixels_above_8':changed,
                            'content_diff_bounds':difference.getbbox(), 'after_content_sha256':hashlib.sha256(b.tobytes()).hexdigest()})
    assert len({item['after_content_sha256'] for item in comparisons}) == 1, 'Effects must return to identical content baseline'
    (directory/'pixel-comparison.json').write_text(json.dumps(comparisons, indent=2), encoding='utf-8')
    return comparisons


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--pixels', action='store_true')
    parser.add_argument('--camera', action='store_true')
    parser.add_argument('--isolation', action='store_true')
    args = parser.parse_args()
    directory = args.evidence.resolve()
    if args.worker:
        private_station()
        env = dict(os.environ)
        env['GRAFFITTY_INPUT_EVIDENCE'] = str(directory)
        env['GRAFFITTY_INPUT_PYTHON'] = sys.executable
        template = next(c for c in dashboard.cases() if c['suite']=='windows' and c['name']=='powershell-7')
        dashboard.configure_owner(template, env, directory)
        with dashboard.PrivateServer(env, directory, template['shell']) as owner:
            replay = 'effects-isolation' if args.isolation else 'effects-camera' if args.camera else 'effects-pixels' if args.pixels else 'effects-settings'
            with (directory/'replay.log').open('wb') as log:
                result = subprocess.run([dashboard.GODOT, '--path', str(args.project.resolve()), '--script',
                    str(ROOT/('tests/llm-e2e/suites/godot/integration/replays/'+replay+'.gd')), '--', '--shell='+template['shell']],
                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=75)
            (directory/'owner-build.json').write_text(json.dumps({'path':str(owner.binary),'sha256':hashlib.sha256(owner.binary.read_bytes()).hexdigest()}))
        return result.returncode
    directory.mkdir(parents=True, exist_ok=False)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CODEX_','CLAUDE_'))}
    for kind in ('CONFIG','STATE','CACHE','DATA'): env['XDG_'+kind+'_HOME']=str(directory/kind.lower())
    report = {'status':'FAIL', 'scope':'Effects controls; pixel matrix recorded separately'}
    try:
        command = [sys.executable,'-X','utf8',__file__,'--worker','--project',str(args.project.resolve()),'--evidence',str(directory)]
        if args.pixels: command.append('--pixels')
        if args.camera: command.append('--camera')
        if args.isolation: command.append('--isolation')
        report['scope'] = 'Typing camera projection and decay' if args.camera else 'Trails and particle pixels; camera projection separate' if args.pixels else report['scope']
        report['isolation'] = windows_private_desktop.run(command,env=env,cwd=ROOT,log=directory/'worker.log',timeout=90)
        log = (directory/'replay.log').read_text(encoding='utf-8',errors='replace')
        report['checks'] = dashboard.CHECK.findall(log)
        marker = 'EFFECTS_ISOLATION_REPLAY_PASS' if args.isolation else 'EFFECTS_CAMERA_REPLAY_PASS' if args.camera else 'EFFECTS_PIXELS_REPLAY_PASS' if args.pixels else 'EFFECTS_SETTINGS_REPLAY_PASS'
        assert report['isolation']['exit_code']==0 and marker in log, log[-4000:]
        assert not any(line.lstrip().startswith(('ERROR:','SCRIPT ERROR:','WARNING:')) for line in log.splitlines()), log
        if args.pixels: report['pixels'] = compare_pixels(directory)
        report['status']='PASS'
    except Exception as error: report['error']=str(error)
    extension=args.project.resolve()/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    report['extension']={'path':str(extension),'sha256':hashlib.sha256(extension.read_bytes()).hexdigest()}
    (directory/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    return report['status']!='PASS'


if __name__ == '__main__': sys.exit(main())
