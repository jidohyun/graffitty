#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Twice kill an owned Chromium GPU child; require document and video recovery."""
import json
from pathlib import Path
import subprocess
import sys
import time
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import main, evaluate, eventually, sample, Stream, PAGE, quote


def exercise(matrix, out, descriptor):
    assert matrix.args.platform in ['macos', 'windows'], 'Linux GPU recovery uses linux_chromium_stress_e2e.py'
    owner = Workspace(descriptor, 'gpu-recovery'); stream = None; cef_log = None
    try:
        browser = owner.rpc('chromium.create',url='about:blank')['chromium']; sid = int(browser[1:])
        owner.client.until(lambda:any(b['id']==sid and b['state'].get('chromiumId',-1)>0 for b in owner.client.topology['chromiums']))
        state = next(b['state'] for b in owner.client.topology['chromiums'] if b['id']==sid)
        host = state['pid']
        if matrix.args.platform == 'macos': cef_log = Path(state['runtimeDirectory']) / 'cef.log'
        owner.rpc('chromium.command',chromium=browser,action='resize',args={'width':800,'height':600})
        assert evaluate(owner.rpc,browser,'document.open();document.write('+json.dumps(PAGE)+');document.close();window.stressIdentity="retained";true')
        assert evaluate(owner.rpc,browser,'window.gpuRecoveryTicks=0;requestAnimationFrame(function tick(){++window.gpuRecoveryTicks;requestAnimationFrame(tick)});true')
        stream = Stream(descriptor,sid,workspace='gpu-recovery')
        eventually(lambda:len(stream.sample)>=60,'Initial video missing')
        results = {'browser_pid':host, 'initial':stream.decode(out,'initial'), 'cycles':[]}
        for cycle in range(1, 3):
            old = sample(matrix,out)
            gpu_pids = {p['pid'] for p in old['descendants'] if p['chromium_type']=='gpu-process'}
            assert gpu_pids, 'No owned GPU process'
            ticks = evaluate(owner.rpc,browser,'window.gpuRecoveryTicks')
            if matrix.args.platform == 'windows':
                command = '& '+quote(matrix.args.python)+' '+quote(matrix.remote+'/fixture.py')+' kill --directory '+quote(matrix.remote+'/'+out.name)+' --host-pid '+str(host)+' --kind gpu'
                killed = matrix.ps(command+"\nif ($LASTEXITCODE -ne 0) {throw 'Owned GPU termination failed'}")
            else:
                killed = subprocess.check_output([sys.executable,str(matrix.helper),'kill','--directory',str(out/'owner'),'--host-pid',str(host),'--kind','gpu'],text=True,timeout=15)
            started = time.monotonic()
            record = {'cycle':cycle,'killed':json.loads(killed),'old_gpu_pids':sorted(gpu_pids)}
            try:
                eventually(lambda:stream.stats(started)['frames']>=60,'Video did not recover after GPU child exit',timeout=40)
            except Exception:
                diagnostics = {'cycle':cycle,'stream_error':stream.error,'stream':stream.stats(started),'processes':sample(matrix,out)}
                try:
                    ticket = owner.rpc('chromium.command',chromium=browser,action='chrome-state',args={})['ticket']
                    diagnostics['state'] = eventually(lambda:owner.rpc('chromium.result',chromium=browser,ticket=ticket),'State result missing')
                    diagnostics['document'] = evaluate(owner.rpc,browser,'[window.stressIdentity,document.visibilityState,window.gpuRecoveryTicks]')
                    owner.rpc('chromium.command',chromium=browser,action='resize',args={'width':802,'height':602})
                    probe_started = time.monotonic(); time.sleep(5)
                    diagnostics['after_resize'] = stream.stats(probe_started)
                    diagnostics['ticks_after_resize'] = evaluate(owner.rpc,browser,'window.gpuRecoveryTicks')
                    stream.action('subscribe',sessions=[]); time.sleep(1)
                    stream.action('subscribe',sessions=[sid])
                    probe_started = time.monotonic(); time.sleep(5)
                    diagnostics['after_resubscribe'] = stream.stats(probe_started)
                except Exception as error:
                    diagnostics['control_error'] = str(error)
                (out/'failure-diagnostics.json').write_text(json.dumps(diagnostics,indent=2))
                raise
            assert evaluate(owner.rpc,browser,'window.stressIdentity') == 'retained', 'GPU recovery replaced the document'
            recovered_ticks = evaluate(owner.rpc,browser,'window.gpuRecoveryTicks')
            assert recovered_ticks > ticks, 'Renderer animation did not resume'
            replacement = sample(matrix,out)
            fresh_gpu = {p['pid'] for p in replacement['descendants'] if p['chromium_type']=='gpu-process'}
            assert fresh_gpu - gpu_pids, replacement
            assert any(p['pid']==host for p in replacement['descendants']), 'Browser host was replaced'
            stream.reset_sample()
            eventually(lambda:len(stream.sample)>=60,'Fresh recovered frames missing',timeout=30)
            record.update(recovered=stream.decode(out,'recovered-'+str(cycle)),seconds=time.monotonic()-started,
                          new_gpu_pids=sorted(fresh_gpu),document_retained=True,
                          ticks_before=ticks,ticks_after=recovered_ticks)
            results['cycles'].append(record)
            (out/'gpu-recovery.json').write_text(json.dumps(results,indent=2))
    finally:
        try:
            if cef_log is not None:
                for name in ('cef.log', 'startup-trace.json'):
                    source = cef_log.with_name(name)
                    if source.is_file(): (out/name).write_bytes(source.read_bytes())
        finally:
            try:
                if stream: stream.close()
            finally:
                owner.close()


if __name__ == '__main__': raise SystemExit(main(exercise,__doc__))
