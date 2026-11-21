"""Private notification delivery adapter: records requests; never calls OS UI/audio."""
import json
from pathlib import Path
import queue
import sys
import threading
import time

directory=Path(sys.argv[1])
request=json.loads(sys.stdin.readline())
(directory/(request['native_id']+'.json')).write_text(json.dumps(request),encoding='utf-8')
closed=queue.Queue()
threading.Thread(target=lambda:closed.put(sys.stdin.readline()),daemon=True).start()
started=time.monotonic()
while True:
    try:
        closed.get(timeout=.02)
        result={'clicked':False}
        break
    except queue.Empty:
        response=directory/(request['native_id']+'.response.json')
        if response.exists():
            result=json.loads(response.read_text(encoding='utf-8'))
            break
        if request['timeout']>0 and (time.monotonic()-started)*1000>=request['timeout']:
            result={'clicked':False}
            break
print(json.dumps(result),flush=True)
