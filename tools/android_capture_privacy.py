"""Save only application pixels from the unfolded Fold7 demo capture.

Unredacted device video must remain in a temporary directory outside the repo.
The compositor restores geometry with blank system regions, never original pixels.
"""
import json
import subprocess
from pathlib import Path

DISPLAY = [1968, 2184]
APP_RECT = [0, 90, 1968, 1968]
FILTER = 'crop=1968:1968:0:90'

def metadata(output):
    (Path(output) / 'screen-crop.json').write_text(json.dumps({
        'source_display': DISPLAY, 'app_rect': APP_RECT,
        'system_bars_removed': True,
    }, indent=2) + '\n')

def crop_video(source, target):
    video = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height', '-of', 'json', str(source)
    ]))['streams'][0]
    if [video['width'], video['height']] != DISPLAY:
        raise RuntimeError('Unknown capture geometry; refusing to save uncropped recording')
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', str(source), '-map', '0:v:0', '-vf', FILTER, '-an',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16',
        '-fps_mode', 'passthrough', '-movflags', '+faststart', str(target)], check=True)

def capture_screen(adb, target):
    # Pixels go directly through the crop pipe, never through a repo raw PNG.
    pixels = subprocess.check_output(adb + ['exec-out', 'screencap', '-p'])
    # PNG IHDR dimensions are available without retaining the private image.
    import struct
    if list(struct.unpack('>II', pixels[16:24])) != DISPLAY:
        raise RuntimeError('Unknown screenshot geometry; refusing to save uncropped image')
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'image2pipe', '-i', 'pipe:0', '-vf', FILTER,
        '-frames:v', '1', str(target)], input=pixels, check=True)
