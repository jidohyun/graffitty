#!/usr/bin/env python3
# /// script
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Validate and run the mandatory shared E2E matrix for every frontend.

This runner never substitutes core tests or another frontend's PASS for a missing
frontend adapter. A schema-only validation does not constitute acceptance.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tomllib

ROOT=Path(__file__).resolve().parents[2]
SUITES=ROOT/'tests/llm-e2e/suites/shared'
FRONTENDS=('godot',)
TARGETS=FRONTENDS

def catalog(root=SUITES):
    cases=[]
    for path in sorted(root.glob('*/*.toml')):
        data=tomllib.loads(path.read_text(encoding='utf-8'))
        required=data.get('required_frontends')
        if not isinstance(required,list) or len(required)!=len(FRONTENDS) or set(required)!=set(FRONTENDS):
            raise ValueError(f'{path}: shared cases must require exactly {", ".join(FRONTENDS)}')
        instructions=(path.parent/data.get('instructions',path.stem+'.md')).resolve()
        if not instructions.is_file():raise ValueError(f'{path}: missing instructions {instructions}')
        adapters=data.get('adapters',{})
        platforms=data.get('platforms', [])
        if not isinstance(platforms, list) or any(p not in ('windows','macos','linux') for p in platforms):
            raise ValueError(f'{path}: platforms must list windows, macos or linux')
        if set(adapters)-set(TARGETS):raise ValueError(f'{path}: unknown frontend adapter')
        for frontend,adapter in adapters.items():
            if 'timeout_seconds' in adapter and (type(adapter['timeout_seconds']) is not int or adapter['timeout_seconds'] <= 0):
                raise ValueError(f'{path}: timeout_seconds must be a positive integer')
            if adapter.get('kind') not in ('godot-replay','android-runtime','manual','python'):
                raise ValueError(f'{path}: invalid {frontend} adapter kind')
            for field in ('replay','script'):
                if field in adapter and not (path.parent/adapter[field]).resolve().is_file():
                    raise ValueError(f'{path}: missing {frontend} {field}')
            if adapter.get('kind')=='godot-replay' and frontend!='godot':
                raise ValueError(f'{path}: Godot replay cannot certify {frontend}')
            if adapter.get('kind')=='python' and 'script' not in adapter:
                raise ValueError(f'{path}: Python adapter requires a script')
            if any(v not in ('windows','macos','linux') for v in adapter.get('platforms', [])):
                raise ValueError(f'{path}: {frontend} adapter platforms must list windows, macos or linux')
            for field in ('args', 'coverage_gaps', 'platforms'):
                if field in adapter and (not isinstance(adapter[field], list) or
                                         not all(isinstance(v, str) for v in adapter[field])):
                    raise ValueError(f'{path}: {field} must be a list of strings')
        cases.append(dict(data,spec=str(path),instructions_path=str(instructions),
                          id=path.parent.name+'/'+path.stem))
    return cases

def planned(case,frontend,headful=False):
    platform='windows' if os.name=='nt' else 'macos' if sys.platform=='darwin' else 'linux'
    if case.get('platforms') and platform not in case['platforms']:
        return {'status':'NOT_APPLICABLE','reason':f'Requires {", ".join(case["platforms"])}; current platform is {platform}'}
    adapter=case.get('adapters',{}).get(frontend)
    if not adapter:
        return {'status':'BLOCKED','reason':f'No {frontend} adapter executes all assertions of this shared case'}
    if adapter.get('platforms') and platform not in adapter['platforms']:
        return {'status':'BLOCKED','reason':f'The {frontend} adapter runs on {", ".join(adapter["platforms"])}; current platform is {platform}'}
    if adapter['kind']=='manual':
        return {'status':'BLOCKED','reason':adapter.get('reason','Manual execution with recorded evidence required')}
    if adapter['kind']=='godot-replay' and case.get('requires_headful',False) and not headful:
        return {'status':'BLOCKED','reason':'This case requires native focus/input; run its Godot replay with --headful and record evidence'}
    return {'status':'NOT_RUN','adapter':adapter}

sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
def execute(case,frontend,directory,android_serial=None,binaries=None,headful=False):
    result=planned(case,frontend,headful)
    if result['status'] in ('BLOCKED','NOT_APPLICABLE'):return result
    adapter=result['adapter'];kind=adapter['kind'];directory.mkdir(parents=True)
    started=time.monotonic()
    if kind=='godot-replay':
        # Import lazily: listing/schema validation only needs the standard library.
        import test_dashboard as dashboard
        matching=[c for c in dashboard.cases() if c['suite']==case['id'].split('/')[0] and c['name']==case['name']]
        if len(matching)!=1:raise ValueError('Shared Godot adapter is not uniquely discoverable')
        report=dashboard.test_one(matching[0],'',headful=headful)
        result={'status':report['status'].upper(),'evidence':report}
        if result['status'] not in ('PASS','FAIL','BLOCKED'):result['status']='FAIL'
    elif kind=='android-runtime':
        if not android_serial:
            return {'status':'BLOCKED','reason':'Select an authorized Android emulator/phone with --android-serial'}
        command=['uv','run',str(ROOT/'tests/android/test_android_runtime.py'),adapter['case'],
                 '--serial',android_serial,'--output',str(directory/'android')]
        result=run_command(command,directory)
    else:
        script=(Path(case['spec']).parent/adapter['script']).resolve()
        command=['uv','run',str(script),*adapter.get('args',[]),'--evidence',str(directory/'fixture')]
        if adapter.get('binary_argument'):
            binary=(binaries or {}).get(frontend)
            if binary is None:
                return {'status':'BLOCKED','reason':f'Select the built frontend with --{frontend}-binary'}
            command.extend([adapter['binary_argument'],str(binary)])
        result=run_command(command,directory)
    if adapter.get('coverage_gaps'):
        result['automated_status']=result['status']
        result['coverage_gaps']=adapter['coverage_gaps']
        if result['status']=='PASS':result['status']='BLOCKED'
    result['seconds']=round(time.monotonic()-started,3)
    return result

def run_command(command,directory):
    with (directory/'run.log').open('w',encoding='utf-8') as log:
        process=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,
                               env=dict(os.environ,PYTHONUTF8='1'))
    return {'status':{0:'PASS',2:'BLOCKED'}.get(process.returncode,'FAIL'),
            'exit_code':process.returncode,'command':command,'log':str(directory/'run.log')}

def overall(matrix):
    statuses={value['status'] for row in matrix.values() for value in row.values()}
    if 'FAIL' in statuses:return 'FAIL'
    if 'BLOCKED' in statuses:return 'BLOCKED'
    if 'NOT_RUN' in statuses:return 'NOT_RUN'
    if statuses=={'NOT_APPLICABLE'}:return 'NOT_APPLICABLE'
    return 'PASS' if statuses else 'BLOCKED'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--validate',action='store_true',help='Validate schema/paths only; does not certify coverage')
    mode.add_argument('--run',action='store_true',help='Execute every available selected frontend adapter')
    parser.add_argument('--case',action='append',help='Category/case ID; repeat to select cases')
    parser.add_argument('--frontend',choices=(*TARGETS,'all'),default='all')
    parser.add_argument('--android-serial')
    parser.add_argument('--headful',action='store_true',help='Include native Godot focus/input tests using visible test windows')
    parser.add_argument('--evidence',type=Path,help='New output directory for matrix and execution evidence')
    args=parser.parse_args();cases=catalog()
    if args.case:
        unknown=set(args.case)-{c['id'] for c in cases}
        if unknown:parser.error('Unknown shared cases: '+', '.join(sorted(unknown)))
        cases=[c for c in cases if c['id'] in args.case]
    if args.validate:
        print(f'Validated {len(cases)} shared specifications; all require {", ".join(FRONTENDS)}. No tests executed.')
        return 0
    if args.run and not args.evidence:parser.error('--run requires a new --evidence directory')
    if args.evidence:args.evidence.mkdir(parents=True,exist_ok=False)
    frontends=FRONTENDS if args.frontend=='all' else (args.frontend,)
    binaries={}
    matrix={}
    for case in cases:
        matrix[case['id']]={}
        for frontend in frontends:
            result=(execute(case,frontend,args.evidence/case['id']/frontend,args.android_serial,binaries,args.headful)
                    if args.run else planned(case,frontend,args.headful))
            matrix[case['id']][frontend]=result
    status=overall(matrix)
    report={'status':status,'required_frontends':list(FRONTENDS),'selected_frontends':list(frontends),
            'complete_frontend_matrix':args.frontend=='all','execution_requested':args.run,
            'visual_review':'Required where the shared procedure calls for rendered/recorded evidence',
            'cases':matrix}
    if args.evidence:(args.evidence/'matrix.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))
    return 1 if status=='FAIL' else 0 if status=='PASS' and args.frontend=='all' else 2

if __name__=='__main__':raise SystemExit(main())
