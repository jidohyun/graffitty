#!/usr/bin/env python3
"""Concurrent native CLI checkpoint writers/readers with bounded retention."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import sys


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cli',type=Path,required=True);p.add_argument('--artifacts',type=Path,required=True)
    args=p.parse_args();out=args.artifacts.resolve();out.mkdir(parents=True)
    env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_','CODEX_','CLAUDE_'))}
    env.update(GRAFFITTY_CHECKPOINT_DIR=str(out/'history'),GRAFFITTY_CHECKPOINT_HISTORY='4')
    for kind in ['CONFIG','STATE','DATA','CACHE']:env['XDG_'+kind+'_HOME']=str(out/kind.lower())
    def call(*command):
        r=subprocess.run([str(args.cli.resolve()),'checkpoint',*command],env=env,capture_output=True,text=True,encoding="utf-8",timeout=60)
        return {'operation':command[0],'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
    documents=[]
    for i in range(24):
        d={'version':1,'windows':[{'active':1,'position':[0,0],'size':[800,600],'tabs':[{'id':1,'focused':'%1','tree':{'pane':'%1'}}],'panes':[{'id':1,'pid':os.getpid(),'cwd':str(out),'title':'writer-'+str(i)}],'chromiums':[]}]}
        path=out/('input-'+str(i)+'.json');path.write_text(json.dumps(d));documents.append(path)
    baseline=call('save','--input',str(documents[0]));assert baseline['exit']==0,baseline
    done=threading.Event();reads=[];restores=[]
    def reader():
        while not done.is_set():
            reads.append(call('list'));time.sleep(.01)
    def restorer():
        while not done.is_set():
            restores.append(call('restore','--checkpoint','0','--prepare-only'));time.sleep(.01)
    thread=threading.Thread(target=reader);restore_thread=threading.Thread(target=restorer)
    thread.start();restore_thread.start()
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            writes=list(pool.map(lambda path:call('save','--input',str(path)),documents))
    finally:
        done.set();thread.join(timeout=65);restore_thread.join(timeout=65)
    assert not thread.is_alive() and not restore_thread.is_alive()
    final=call('list');all_results=[baseline,*writes,*reads,*restores,final]
    (out/'operations.json').write_text(json.dumps(all_results,indent=2))
    errors=[r for r in all_results if r['exit']!=0]
    assert not errors,errors
    for result in reads:
        entries=json.loads(result['stdout']);assert 1 <= len(entries) <= 4,entries
    for result in restores:
        prepared=Path(json.loads(result['stdout'])['prepared'])
        assert json.loads(prepared.read_text())['windows'][0]['panes'][0]['title'].startswith('writer-')
    entries=json.loads(final['stdout']);assert len(entries)==4,entries
    for entry in entries:
        d=json.loads(Path(entry['path']).read_text());assert d['windows'][0]['panes'][0]['title'].startswith('writer-')
    assert not list((out/'history').rglob('*.tmp'))
    (out/'result.json').write_text(json.dumps({'status':'pass','platform':sys.platform,'writers':len(writes),'concurrent_reads':len(reads),'concurrent_restores':len(restores),'retained':len(entries),'cli_sha256':hashlib.sha256(args.cli.read_bytes()).hexdigest()},indent=2))
    print(sys.platform,'concurrent checkpoint writes/readers passed')


if __name__=='__main__':main()
