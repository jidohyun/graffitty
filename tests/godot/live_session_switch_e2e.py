#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Shared-matrix entry point retaining Godot live-session acceptance evidence."""
import argparse,json,os,unittest
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()
a.evidence.mkdir(parents=True,exist_ok=True);os.environ['GRAFFITTY_TEST_EVIDENCE']=str(a.evidence.resolve())
import test_live_session_switch as tests
with (a.evidence/'unittest.log').open('w') as stream:
    result=unittest.TextTestRunner(stream=stream,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(tests))
(a.evidence/'results.json').write_text(json.dumps({'status':'PASS' if result.wasSuccessful() else 'FAIL',
    'tests':result.testsRun,'failures':[message for _,message in result.failures],
    'errors':[message for _,message in result.errors]},indent=2))
raise SystemExit(0 if result.wasSuccessful() else 1)
