"""Exercise Godot's actual startup validation without creating any session owner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--invalid-color-only', action='store_true')
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    for kind in ('CONFIG', 'STATE', 'CACHE', 'DATA'):
        env['XDG_' + kind + '_HOME'] = str(evidence / kind.lower())
    # A validation launch must never reach session creation.
    env['GRAFFITTY_SERVER'] = str(evidence / 'must-not-launch-owner.exe')
    automatic = evidence / 'config/graffitty/client.toml'
    automatic.parent.mkdir(parents=True)
    automatic.write_text('[window]\nmax_fps = 73\n[terminal]\nfont_size = 17\n', encoding='utf-8')
    first = evidence / 'first.toml'
    first.write_text('[window]\ninactive_max_fps = 19\n[terminal]\nfont_size = 21\n', encoding='utf-8')
    second = evidence / 'second.toml'
    second.write_text('[terminal]\nfont_size = 23\n', encoding='utf-8')
    sources = [automatic, first, second]
    checks = []

    def run(name, flags, expected=0):
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        command = [env['GRAFFITTY_GODOT'], '--headless', '--path', str(args.project.resolve()), '--', *flags]
        result = subprocess.run(command, env=env, capture_output=True, timeout=20)
        log = result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace')
        (evidence / (name + '.log')).write_text(log, encoding='utf-8')
        assert result.returncode == expected, (name, result.returncode, log)
        assert 'SCRIPT ERROR:' not in log and 'leaked' not in log, (name, log)
        assert before == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, name
        checks.append(name)
        return next((json.loads(line) for line in log.splitlines() if line.startswith('{"font_paths"')), None)

    if args.invalid_color_only:
        source = evidence / 'invalid-color.toml'
        source.write_text('[terminal]\nforeground = "not-a-color"\n', encoding='utf-8')
        sources.append(source)
        run('invalid-color', ['--no-config', '--check-config', '--config='+str(source)], 2)
        log = (evidence/'invalid-color.log').read_text(encoding='utf-8')
        assert 'Unknown' not in log and 'color' in log.lower(), log
        (evidence/'report.json').write_text(json.dumps({'status':'PASS','checks':checks,'scope':'The foreground key rejects a malformed color before owner launch'}),encoding='utf-8')
        return
    flags = ['--check-config', '--config=' + str(first), '--config=' + str(second)]
    effective = run('precedence', flags)
    assert effective['font_size'] == 23 and effective['max_fps'] == 73 and effective['inactive_max_fps'] == 19
    effective = run('no-config', flags + ['--no-config'])
    assert effective['font_size'] == 23 and effective['max_fps'] == 120 and effective['inactive_max_fps'] == 19
    font = evidence / 'relative.ttf'
    shutil.copyfile(Path(os.environ['WINDIR']) / 'Fonts/consola.ttf', font)
    relative = evidence / 'relative.toml'
    relative.write_text('[terminal]\nfont_regular_path = "relative.ttf"\n', encoding='utf-8')
    sources += [font, relative]
    effective = run('relative-font', ['--no-config', '--check-config', '--config=' + str(relative)])
    assert Path(effective['font_paths'][0]) == font
    invalid = {
        'unknown-key': '[terminal]\nnot_a_setting = true\n',
        'invalid-value': '[terminal]\nfont_size = -1\n',
        'invalid-type': '[terminal]\nfont_size = "huge"\n',
        'missing-font': '[terminal]\nfont_regular_path = "missing.ttf"\n',
        'invalid-color': '[terminal]\nforeground = "not-a-color"\n',
        'invalid-window': '[window]\nmax_fps = -1\n',
        'syntax': '[terminal\nfont_size = 20\n',
        'capability-override': '[terminal]\nclipboard_primary_supported = true\n',
        'unknown-action': '[bindings]\nnew_tab = "Ctrl+T"\n',
        'binding-conflict': '[bindings]\nNewTab = "Ctrl+Alt+T"\nShowAllTabs = "Ctrl+Alt+T"\n',
    }
    for name, content in invalid.items():
        source = evidence / (name + '.toml')
        source.write_text(content, encoding='utf-8')
        sources.append(source)
        run(name, ['--no-config', '--check-config', '--config=' + str(source)], 2)
    run('normal-startup-rejects-invalid', ['--no-config', '--config=' + str(evidence / 'unknown-key.toml')], 2)
    assert not list((evidence / 'state').rglob('connection.json'))
    report = {'status': 'PASS', 'checks': checks, 'scope': 'Actual startup validation and early exit; no rendered startup claim',
              'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    (evidence / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
