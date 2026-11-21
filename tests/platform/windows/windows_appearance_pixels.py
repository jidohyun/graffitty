"""Check saved native/window pixels; never rerun an already completed replay."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageChops


def compare(directory, mode):
    checks = []
    def load(name, native=True):
        return Image.open(directory / (name + ('-terminal' if native else '') + '.png')).convert('RGB')
    def check(condition, message):
        checks.append({'status': 'PASS' if condition else 'FAIL', 'check': message})
    def mask(image, channel):
        bands = image.split()
        result = bands[channel].point(lambda x: 255 if x > 180 else 0)
        for i, band in enumerate(bands):
            if i != channel:
                result = ImageChops.multiply(result, band.point(lambda x: 255 if x < 60 else 0))
        return result
    def count(image):
        return sum(image.histogram()[1:])
    def equal(a, b):
        return ImageChops.difference(a, b).getbbox() is None
    def blink(prefix, expected=None):
        a, b = load(prefix+'-a'), load(prefix+'-b')
        box = ImageChops.difference(a, b).getbbox()
        check(box is not None and (expected is None or box == expected), prefix+' changes only the expected cursor rectangle: '+str(box))
        return box
    if mode == 'details':
        prefix = 'appearance-details-'
        before, selected, red, outline = [load(prefix+n) for n in ('before','selected','selection-red','outline')]
        green_mask, red_mask = mask(selected, 1), mask(red, 0)
        check(count(green_mask)>100 and equal(green_mask,red_mask), 'Selection changes actual identical glyph pixels from green to red')
        check(equal(mask(selected,2),mask(red,2)) and count(mask(red,2))>100, 'Blue selection background stays unchanged')
        outline_box = ImageChops.difference(before,outline).getbbox()
        check(count(mask(outline,0))>20 and outline_box is not None and outline_box[3]<120, 'Red outline is confined to the terminal glyph run')
        check(equal(load(prefix+'before',False).crop((0,0,1600,120)),load(prefix+'outline',False).crop((0,0,1600,120))), 'Text outline leaves title and menu pixels identical')
        block, hollow, unfocused, hidden = [mask(load(prefix+n),0) for n in ('application-block','hollow','unfocused','hidden')]
        box = block.getbbox()
        check(box is not None and count(block)==(box[2]-box[0])*(box[3]-box[1]), 'Application block fills its cursor rectangle')
        check(hollow.getbbox()==box and 0<count(hollow)<count(block) and hollow.getpixel(((box[0]+box[2])//2,(box[1]+box[3])//2))==0, 'Forced hollow has edges and empty center despite application bar')
        check(equal(hollow,unfocused), 'Window focus-out notification makes application block hollow')
        check(count(hidden)==0, 'DECTCEM hides cursor')
        blink(prefix+'blink',box)
        height=box[3]-box[1]
        blink(prefix+'scrolled-blink',(box[0],box[1]+height,box[2],box[3]+height))
        check(equal(load(prefix+'steady-a'),load(prefix+'steady-b')), 'Blink-off native frames are byte-identical')
    else:
        default, osc, reset = [load('appearance-palette-'+n) for n in ('default','osc','reset')]
        # These rows are native pixels at the fixture's recorded 2x viewport scale.
        row=lambda image,y:image.crop((50,y,350,y+44))
        check(count(mask(row(default,104),0))>100 and count(mask(row(osc,104),1))>100 and equal(default,reset), 'OSC 4 changes configured red to green; OSC 104 restores configured palette')
        check(equal(row(default,148),row(osc,148)) and equal(row(default,192),row(osc,192)), 'Truecolor and sparse index 240 survive OSC palette override')
        # HDR 2D readback is linear RGB, quantized down to 8-bit PNG.
        def linear(rgb):
            return tuple(int(255*(v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4)) for v in rgb)
        check(linear((18,52,86)) in row(default,148).getdata() and linear((204,51,153)) in row(default,192).getdata(), 'Truecolor and sparse palette have the configured linear RGB in HDR readback')
        opaque, translucent = [load('appearance-'+n,False) for n in ('opaque','translucent')]
        check(not equal(opaque.crop((350,350,1300,850)),translucent.crop((350,350,1300,850))), 'World scenery becomes visible through default background')
        check(equal(opaque.crop((38,227,177,248)),translucent.crop((38,227,177,248))), 'Explicit red application background stays opaque')
        check(equal(opaque.crop((0,0,1600,70)),translucent.crop((0,0,1600,70))) and equal(load('appearance-opaque'),load('appearance-translucent')), 'Opacity leaves menu and native ink unchanged; pane glass changes intentionally')
        box=blink('appearance-cursor')
        check(box is not None and box[2]-box[0]==6 and box[3]-box[1]==44, 'Configured 3px beam spans one 22px cell at native 2x scale')
    report = {'status':'PASS' if all(x['status']=='PASS' for x in checks) else 'FAIL','checks':checks}
    (directory/'pixel-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return report


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,required=True)
    parser.add_argument('--mode',choices=['details','palette'],required=True)
    args=parser.parse_args()
    result=compare(args.evidence,args.mode)
    print(json.dumps(result,indent=2))
    raise SystemExit(result['status']!='PASS')
