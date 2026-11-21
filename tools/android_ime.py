"""Bundle the terminal IME Java bridge into a Godot export template (no engine fork)."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import zipfile

from android_launch import prepare_launch_template

ROOT = Path(__file__).resolve().parents[1]


def prepare_template(sdk: Path, launch: str, destination: Path, kind: str = 'release') -> Path:
    """Add the Java IME bridge to Godot's `android_<kind>.apk` export template."""
    if kind not in ('debug', 'release'): raise ValueError(f'Unknown Android template: {kind}')
    version = subprocess.check_output([launch, '--version'], text=True).strip().split('.')
    version = '.'.join(version[:4])
    if sys.platform == 'darwin':
        templates = Path.home() / 'Library/Application Support/Godot/export_templates'
    elif os.name == 'nt':
        templates = Path(os.environ['APPDATA']) / 'Godot/export_templates'
    else:
        templates = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'godot/export_templates'
    source = templates / version / f'android_{kind}.apk'
    if not source.is_file(): raise RuntimeError(f'Install the Godot {version} export templates: {source}')
    javac = shutil.which('javac')
    homebrew = Path('/opt/homebrew/opt/openjdk/bin/javac')
    if homebrew.exists(): javac = str(homebrew)
    if not javac: raise RuntimeError('A JDK is required to build the Android IME bridge')
    work = destination.parent / f'ime-{kind}'
    classes = work / 'classes'
    dex = work / 'dex'
    # Renamed Java packages must not leave obsolete classes in the next APK.
    for directory in (classes, dex):
        if directory.exists(): shutil.rmtree(directory)
        directory.mkdir(parents=True)
    platforms = sorted((sdk / 'platforms').glob('android-*'), key=lambda p: int(p.name.split('-')[1]))
    android = platforms[-1] / 'android.jar'
    subprocess.run([javac, '--release', '8', '-classpath', str(android), '-d', str(classes),
                    *map(str, (ROOT / 'frontends/godot/android/src').rglob('*.java'))], check=True)
    build_tools = sorted((sdk / 'build-tools').iterdir(), key=lambda p: tuple(int(n) for n in p.name.split('.')))[-1]
    env = dict(os.environ, JAVA_HOME=str(Path(javac).resolve().parent.parent))
    subprocess.run([str(build_tools / ('d8.bat' if os.name == 'nt' else 'd8')), '--min-api', '28',
                    '--lib', str(android), '--output', str(dex),
                    *map(str, classes.rglob('*.class'))], env=env, check=True)
    source = prepare_launch_template(source, work)
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w') as output:
        dex_indices = []
        for item in original.infolist():
            if item.filename.startswith('META-INF/'): continue
            match = re.fullmatch(r'classes(\d*)\.dex', item.filename)
            if match: dex_indices.append(int(match[1] or '1'))
            output.writestr(item, original.read(item.filename))
        output.write(dex / 'classes.dex', f'classes{max(dex_indices, default=0)+1}.dex')
    return destination
