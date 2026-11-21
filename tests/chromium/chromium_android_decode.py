#!/usr/bin/env python3
"""Replay captured H.264 or HEVC through the Android NDK decoder.

The test uses a private directory under /data/local/tmp and leaves
the user's app alone.

- Include 1000x700 in the fixture's frame sizes.
- Check that each presented frame matches the stream's dimensions.
- Check codec logs for native failures. Codec2 can report errors even
  when the NDK call succeeds.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stream', type=Path)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--decoder', required=True, help='Named hardware decoder reported by the device')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--ndk', type=Path, default=Path(os.environ.get('ANDROID_NDK_HOME', str(Path.home()/'Library/Android/sdk/ndk/28.1.13356709'))))
    args = parser.parse_args(); out = args.evidence.resolve(); out.mkdir(parents=True, exist_ok=False)
    info = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','stream=codec_name,width,height:packet=pos,size','-of','json',str(args.stream)]))
    stream = info['streams'][0]; codec = {'h264':0,'hevc':1}[stream['codec_name']]
    data = args.stream.read_bytes()
    with (out/'packets.bin').open('wb') as output:
        for packet in info['packets']:
            start, size = int(packet['pos']), int(packet['size'])
            output.write(struct.pack('<I',size)); output.write(data[start:start+size])
    compiler = next(args.ndk.glob('toolchains/llvm/prebuilt/*/bin/aarch64-linux-android26-clang'))
    subprocess.run([str(compiler),'-O2',str(ROOT/'tests/native/chromium_android_decode.c'),'-lmediandk','-llog','-ldl','-o',str(out/'probe')],check=True)
    adb = ['adb','-s',args.serial]; remote = '/data/local/tmp/graffitty-decode-'+uuid.uuid4().hex
    report = {'status':'FAIL','stream':stream,'stream_sha256':hashlib.sha256(data).hexdigest(),'decoder':args.decoder}
    subprocess.run(adb+['shell','mkdir',remote],check=True)
    try:
        subprocess.run(adb+['push',str(out/'probe'),str(out/'packets.bin'),remote+'/'],check=True)
        command = [remote+'/probe',remote+'/packets.bin',str(codec),args.decoder,str(stream['width']),str(stream['height'])]
        run = subprocess.run(adb+['shell',shlex.join(command)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
        (out/'stdout.txt').write_text(run.stdout)
        pid = re.search(r'^PID (\d+)$',run.stdout,re.M)
        assert pid, run.stdout
        logs = subprocess.check_output(adb+['logcat','-d','--pid='+pid[1]],text=True,timeout=30)
        (out/'logcat.txt').write_text(logs)
        result = re.search(r'^RESULT (.*)$',run.stdout,re.M)
        assert result and run.returncode == 0, run.stdout
        report.update(json.loads(result[1]))
        failures = [line for line in logs.splitlines() if any(token in line for token in ('attachBuffer failed','queueBuffer failed','rendring output error','E GraffittyVideo'))]
        report['native_failures'] = failures
        assert not failures, f'{len(failures)} native rendering failures'
        assert report['frames'] > 0 and report['packets'] == len(info['packets']), report
        report['status'] = 'PASS'
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        subprocess.run(adb+['shell','rm','-rf',remote],check=False)
        (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__ == '__main__': main()
