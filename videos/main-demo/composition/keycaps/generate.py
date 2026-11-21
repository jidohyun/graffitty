"""python3 videos/main-demo/composition/keycaps/generate.py
SVG adaptation of Keyty PBTKeycapRenderer/PBTKeycapMetrics (BSD-3-Clause).
Copyright (c) 2026, Serhii Bykov. See KEYTY-LICENSE.txt.
"""
from pathlib import Path
import json

ROOT=Path(__file__).resolve().parent
LEGENDS=json.loads((ROOT/'legends.json').read_text())

# KeycapAppearance+PBT.swift: same blend factors with neutral theme tokens.
def blend(color, fraction, endpoint=255):
    channels=[int(color[i:i+2],16) for i in (0,2,4)]
    return '#'+''.join(f'{round(c+(endpoint-c)*fraction):02x}' for c in channels)
BASE, SHADOW = 'b3b4b5', '8f9193'
BODY_TOP, BODY_MID, BODY_BOTTOM = blend(BASE,.08), blend(SHADOW,.03), blend(SHADOW,.08,0)
DISH_TOP, DISH_MID, DISH_BOTTOM = blend(BASE,.05), blend(BASE,.06), blend(SHADOW,.05)
UNDER_DISH = blend(BASE,.12)


for name,width in [('cmd',114),('ctrl',126),('shift',126),('alt',126),('enter',154),('2',100),('3',100),('a',100),('colon',100),('minus',100),('underscore',100)]:
    # AppKit's y axis points up; SVG's points down. Keyty uses rim=13,
    # bodyInset=2, dishLift=8, 18/10 radii, and 2.5 px of key travel.
    for pressed in [False,True]:
        y=7+(2.5 if pressed else 0)
        face_width=width-30
        labels=LEGENDS[name]
        svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="100" viewBox="0 0 {width} 100">
<!-- Adapted from Keyty's PBT renderer; Copyright (c) 2026 Serhii Bykov; BSD-3-Clause; see KEYTY-LICENSE.txt -->
<defs>
 <linearGradient id="body" x1="0" y1="0" x2="1" y2="1"><stop stop-color="{BODY_TOP}"/><stop offset=".48" stop-color="{BODY_MID}"/><stop offset="1" stop-color="{BODY_BOTTOM}"/></linearGradient>
 <linearGradient id="dish" x1="1" y1="1" x2="0" y2="0"><stop stop-color="{DISH_TOP}"/><stop offset=".32" stop-color="{DISH_MID}"/><stop offset="1" stop-color="{DISH_BOTTOM}"/></linearGradient>
</defs>
<rect x="2" y="2" width="{width-4}" height="96" rx="18" fill="url(#body)" stroke="#797f84" stroke-opacity=".75" stroke-width="1.5"/>
<rect x="15" y="{y+2.5}" width="{face_width}" height="70" rx="10" fill="{UNDER_DISH}"/>
<rect x="15" y="{y}" width="{face_width}" height="70" rx="10" fill="url(#dish)"/>
<g fill="#24282d" transform="translate(0 {2.5 if pressed else 0})">{labels}</g></svg>'''
        (ROOT/f'{name}{"-pressed" if pressed else ""}.svg').write_text(svg)
