"""Place the captured native Chromium window on the desktop movie's frame cues."""
import json
from pathlib import Path
import shutil
import subprocess


def active_chrome(root, take):
    """Select a genuinely active captured title bar, not the first frame."""
    video=take/'native-window.mp4'
    scan=subprocess.run(['ffmpeg','-v','error','-i',str(video),'-vf','crop=160:70:0:0',
        '-f','rawvideo','-pix_fmt','rgb24','-'],check=True,capture_output=True).stdout
    size=160*70*3
    selected=None
    for frame in range(len(scan)//size):
        offset=frame*size
        def pixel(x):
            begin=offset+(41*160+x)*3
            return scan[begin:begin+3]
        red,green=pixel(40),pixel(132)
        if red[0]>180 and red[0]>red[1]*1.4 and green[1]>green[0]*1.4:
            selected=frame
            break
    if selected is None:
        raise ValueError('No active Chromium title bar found in the cached capture')
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(video),'-vf',f'select=eq(n\\,{selected})',
        '-frames:v','1',str(root/'assets/native-window-active-chrome.png')],check=True)
    return selected


def compose(root: Path, take: Path, capture: dict, timeline_time):
    native = capture.get("native_window")
    if native is None:
        return "", ""
    start = timeline_time(native["start_frame"] / 60)
    end = timeline_time(native["end_frame"] / 60)
    duration = end - start
    if duration < 6.4 - 1 / 120 or abs(duration - (native["end_frame"] - native["start_frame"]) / 60) > 1 / 120:
        raise ValueError("Native window reveal must preserve every source frame at 1x and allow the concise drags")
    if native.get("composited_scene"):
        duration += native.get("cursor_return_frames", 0) / 60
        asset = "assets/reused-native-scene.mp4"
        shutil.copyfile(take / native["composited_scene"], root / asset)
        native.update(timeline_start=start, timeline_end=end)
        (root / "native-window-capture.json").write_text(json.dumps(native, indent=2) + "\n")
        return (f'    <!-- native-window:start -->\n'
                f'    <video id="reused-native-scene" class="clip" src="{asset}" muted playsinline '
                f'data-start="{start:.6f}" data-duration="{duration:.6f}" data-playback-rate="1" '
                'data-track-index="8" style="position:absolute;inset:0;width:1920px;height:1080px;z-index:8"></video>\n'
                '    <!-- native-window:end -->', '')
    scale = .56
    width, height = native["width"] * scale, native["height"] * scale
    if width > 1100 or height > 650:
        raise ValueError("Native window capture does not fit the authored drag path")
    shutil.copyfile(take / "native-window.mp4", root / "assets/native-window.mp4")
    # The first capture's alpha is the actual macOS window silhouette. Keep
    # those corners when encoding the color footage to opaque H.264.
    shutil.copyfile(take / "native-window-shape.png", root / "assets/native-window-shape.png")
    pointer_scale = scale * capture["ui_scale"]
    pointer_x = 288 + native["pointer_source"][0] * pointer_scale
    pointer_y = 56 + native["pointer_source"][1] * pointer_scale
    return_duration = native.get("cursor_return_frames", 0) / 60
    # Keep an actually active captured title bar above focus changes in the
    # live page. The first capture can be inactive while automation runs.
    native["active_chrome_frame"] = active_chrome(root, take)
    chrome_height = 174 * scale
    # Keep the same pointer geometry/scale as the Godot replay. The video
    # contains the actual macOS controls, address bar, and Chrome tab strip.
    html = f'''    <!-- native-window:start -->
    <div id="native-chromium" style="position:absolute;inset:0;transform:translateY(56px);pointer-events:none">
      <div id="native-chromium-motion" style="position:absolute;left:0;top:0;width:{width:.3f}px;height:{height:.3f}px;border-radius:30px;box-shadow:0 22px 64px #00000088,0 0 0 1px #00000038;will-change:transform;opacity:0">
        <video id="native-chromium-video" class="clip" src="assets/native-window.mp4" muted playsinline data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="3" data-media-start="0" style="display:block;width:100%;height:100%;object-fit:fill;mask-image:url(assets/native-window-shape.png);mask-size:100% 100%;mask-mode:alpha"></video>
        <img src="assets/native-window-active-chrome.png" alt="" aria-hidden="true" style="position:absolute;inset:0;width:100%;height:100%;mask-image:url(assets/native-window-shape.png);mask-size:100% 100%;mask-mode:alpha;clip-path:inset(0 0 calc(100% - {chrome_height:.3f}px) 0);pointer-events:none">
        <svg id="native-traffic-hover" viewBox="0 0 160 70" width="89.6" height="39.2" style="position:absolute;left:0;top:0;opacity:0;pointer-events:none" aria-hidden="true">
          <circle id="native-close-pressed" cx="40" cy="41" r="13.3" fill="#b83b37" style="opacity:0"/>
          <path d="M35 36L45 46M45 36L35 46" fill="none" stroke="#651b18" stroke-width="2.5" stroke-linecap="round"/>
          <path d="M80 41H92" fill="none" stroke="#795800" stroke-width="2.5"/>
          <path d="M126 35H133L126 42ZM138 47H131L138 40Z" fill="#15551d"/>
        </svg>
      </div>
      <div id="native-chromium-pointer" class="clip" data-start="{start:.6f}" data-duration="{duration + return_duration:.6f}" data-track-index="4" data-track-kind="overlay" style="position:absolute;inset:0">
       <div id="native-chromium-cursor" style="position:absolute;left:0;top:0;width:36.288px;height:49.728px;will-change:transform">
        <svg width="36.288" height="49.728" viewBox="0 0 27 37" style="display:block;overflow:visible"><path d="M0 0V26L7 20L12 31L17 29L12 18H20Z" fill="white" stroke="black" stroke-width="1.6666667" stroke-linejoin="round"/></svg>
       </div>
      </div>
    </div>
    <!-- native-window:end -->'''
    # Cursor and window share exact travel times/eases; the grip never slides.
    # Two quick drags finish before the closing sentence; close on "brings back".
    grip_x, grip_y = width * .55, 21
    script = f'''    // native-window-stage:start
    {{
      const tl = window.__timelines["main"];
      const at = {start:.6f};
      tl.set("#native-chromium-motion", {{x:650, y:160, opacity:1}}, at);
      tl.set("#native-chromium-motion", {{opacity:0}}, {end:.6f});
      tl.set("#native-chromium-cursor", {{x:{pointer_x:.4f}, y:{pointer_y:.4f}}}, at);
      tl.set("#traffic-lights .light", {{backgroundColor:"#8b8e93", borderColor:"#00000022"}}, at);
      tl.set("#window", {{boxShadow:"0 12px 38px #777b8428, 0 0 0 1px #73798340"}}, at);
      tl.to("#native-chromium-cursor", {{x:{650+grip_x:.4f}, y:181, duration:.4, ease:"power2.inOut"}}, at + .25);
      tl.to("#native-chromium-motion", {{x:390, y:230, duration:1, ease:"sine.inOut"}}, at + .8);
      tl.to("#native-chromium-cursor", {{x:{390+grip_x:.4f}, y:251, duration:1, ease:"sine.inOut"}}, at + .8);
      tl.to("#native-chromium-motion", {{x:670, y:150, duration:1, ease:"sine.inOut"}}, at + 2.1);
      tl.to("#native-chromium-cursor", {{x:{670+grip_x:.4f}, y:171, duration:1, ease:"sine.inOut"}}, at + 2.1);
      tl.to("#native-chromium-cursor", {{x:692, y:171, duration:.8, ease:"power2.inOut"}}, at + {duration-1.5:.6f});
      // macOS reveals all three glyphs when the pointer enters the controls.
      tl.set("#native-traffic-hover", {{opacity:0}}, at);
      tl.set("#native-close-pressed", {{opacity:0}}, at);
      tl.set("#native-traffic-hover", {{opacity:1}}, at + {duration-.94:.6f});
      tl.set("#native-close-pressed", {{opacity:1}}, at + {duration-.3:.6f});
      tl.set("#traffic-lights .close", {{backgroundColor:"#ec6765", borderColor:"#00000030"}}, {end:.6f});
      tl.set("#traffic-lights .minimize", {{backgroundColor:"#f2ca44", borderColor:"#00000030"}}, {end:.6f});
      tl.set("#traffic-lights .maximize", {{backgroundColor:"#65c466", borderColor:"#00000030"}}, {end:.6f});
      tl.set("#window", {{boxShadow:"0 24px 70px #080a1080, 0 0 0 1px #73798350"}}, {end:.6f});
    }}
    // native-window-stage:end'''
    if return_duration:
        x, y = native["cursor_return_hotspot"]
        script = script.replace('      // macOS reveals',
            f'      tl.to("#native-chromium-cursor", {{x:{x:.4f}, y:{y - 56:.4f}, duration:.65, ease:"sine.inOut"}}, {end:.6f});\n'
            '      // macOS reveals')
    native.update(timeline_start=start, timeline_end=end,
                  composition_size=[width, height],
                  drag_poses=[{"seconds": 0, "x": 650, "y": 160},
                              {"seconds": 1.8, "x": 390, "y": 230},
                              {"seconds": 3.1, "x": 670, "y": 150}])
    (root / "native-window-capture.json").write_text(json.dumps(native, indent=2) + "\n")
    return html, script
