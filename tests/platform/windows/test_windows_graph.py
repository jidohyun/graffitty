"""Native Windows E2E: Godot AgentAPI/TCP, real CLI nodes, and ConPTY UIs.
Set GRAFFITTY_TEST_GODOT and GRAFFITTY_TEST_CLI; stage bundled ConPTY beside the CLI.
The model-routing test mocks only the external Decisions HTTP endpoint.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
GODOT = os.environ.get("GRAFFITTY_TEST_GODOT", "godot")
CLI = os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft.exe"))

def wait(check, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError("Timed out waiting for graph/UI")

class Terminal:
    """The production server's ConPTY, observed through the real Godot renderer."""
    def __init__(self, argv, call, token):
        self.call, self.token = call, token
        self.call(token, "test.terminal.start")
        wait(lambda: "GFT_READY>" in self.text())
        self.write(subprocess.list2cmdline(argv) + "\r")
    def text(self):
        return self.call(self.token, "test.terminal.text")["text"]
    def write(self, text):
        self.call(self.token, "test.terminal.write", text=text)
    def press(self, key):
        self.call(self.token, "test.terminal.press", key=key)
    def stop(self):
        self.press("Ctrl+C")

@unittest.skipUnless(os.name == "nt", "Windows ConPTY integration suite")
class WindowsGraph(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="graffitty-windows-"))
        self.processes = []
        self.terminals = []
        self.files = []
        log = (self.folder / "host.log").open("w", encoding="utf-8")
        self.files.append(log)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))}
        environment.update(JEV_TEST_DIRECTORY=str(self.folder),
                           XDG_CONFIG_HOME=str(self.folder / "config"),
                           XDG_STATE_HOME=str(self.folder / "state"))
        self.server = PrivateServer(environment, self.folder, "cmd.exe")
        with patch.dict(os.environ, {"GRAFFITTY_TEST_SERVER": CLI}):
            self.server.__enter__()
        self.host = subprocess.Popen([GODOT,"--path",str(ROOT / "frontends/godot/project"),"--script","tests/windows_graph_host.gd","--","--shell=cmd.exe"],
            env=environment, stdout=log, stderr=log)
        try:
            wait(lambda: (self.folder / "ready.json").exists() or self.host.poll() is not None, 30)
            self.assertIsNone(self.host.poll(), (self.folder / "host.log").read_text(encoding="utf-8"))
            self.endpoint = json.loads((self.folder / "ready.json").read_text())["socket"]
            self.assertTrue(self.endpoint.startswith("tcp://127.0.0.1:"))
        except Exception:
            self.host.terminate(); self.host.wait(); self.server.__exit__(None,None,None); log.close(); raise
    def tearDown(self):
        for index, terminal in enumerate(self.terminals):
            (self.folder/f"terminal-{index}.txt").write_text(terminal.text(),encoding="utf-8")
            terminal.stop()
        for process in self.processes:
            if process.poll() is None: process.terminate()
            process.wait(timeout=5)
        if self.host.poll() is None:
            try: self.call(1,"test.quit")
            except (OSError, ValueError): pass
            try: self.host.wait(timeout=5)
            except subprocess.TimeoutExpired: self.host.kill(); self.host.wait()
        self.server.__exit__(None,None,None)
        for file in self.files: file.close()
        print("Artifacts:", self.folder)
    def raw(self, token, method, params=None, version=1, fragment=False):
        address = self.endpoint.removeprefix("tcp://").split(":")
        # The frontend forwards to the owner with its own 10-second deadline.
        # Keep the outer deadline longer so owner failures remain observable.
        with socket.create_connection((address[0],int(address[1])), timeout=15) as peer:
            request = {"id":str(uuid.uuid4()),"version":version,"token":str(token),"method":method,"params":params or {}}
            data = (json.dumps(request)+"\n").encode()
            if fragment:
                for start in range(0,len(data),137): peer.sendall(data[start:start+137])
            else: peer.sendall(data)
            with peer.makefile("rb") as response:
                result=json.loads(response.readline())
            self.assertEqual(result["id"],request["id"])
            return result
    def call(self, token, method, **params):
        result=self.raw(token,method,params)
        self.assertNotIn("error",result)
        if method == "test.terminal.text":
            (self.folder / "terminal-native.json").write_text(json.dumps(result["result"], ensure_ascii=False, indent=2), encoding="utf-8")
        return result["result"]
    def connect(self, source, output, target, port="in", **flags):
        return self.call(1,"graph.connect",**{"from":f"%{source}","from_port":output,"to":f"%{target}","to_port":port,**flags})
    def register(self, token, output="out"):
        self.call(token,"agent.event",kind="custom",event="SessionStart",session_id=f"adapter-{token}")
        self.call(token,"agent.register",name=f"Source {token}",inputs=[{"id":"in"}],outputs=[{"id":output}])
    def inbox(self, token): return self.call(token,"graph.take")["events"]
    def manifest(self, token, name):
        return next((n["manifest"] for n in self.call(1,"graph.list")["nodes"] if n["node"] == f"%{token}" and n.get("manifest",{}).get("name") == name),None)
    def node(self, token, command, *args, terminal=False, env=None):
        environment={**os.environ,"GRAFFITTY_SOCKET":self.endpoint,"GRAFFITTY_TOKEN":str(token),"TERM":"xterm-256color",**(env or {})}
        argv=[CLI,"node",command,*args]
        if terminal:
            if env:
                raise ValueError("Interactive fixture environment belongs in the owned server config")
            result=Terminal(argv,self.call,token);self.terminals.append(result);return result
        log=(self.folder/f"node-{token}-{len(self.processes)}.log").open("w",encoding="utf-8");self.files.append(log)
        process=subprocess.Popen(argv,env=environment,stdin=subprocess.DEVNULL,stdout=log,stderr=log);self.processes.append(process);return process
    def sessions(self):
        paths=[]
        for token,provider in [(2,"claude"),(3,"codex")]:
            path=self.folder/f"{provider}.jsonl"
            records=[]
            for i in range(3):
                message={"role":"user" if i%2==0 else "assistant","content":[{"type":"text" if provider=="claude" else "output_text","text":f"{provider}-{i}"}]}
                records.append({"timestamp":f"2026-10-01T12:00:0{i}Z", **({"type":message["role"],"message":message} if provider=="claude" else {"type":"response_item","payload":{"type":"message",**message}})})
            path.write_text("".join(json.dumps(record)+"\n" for record in records),encoding="utf-8")
            self.call(token,"agent.event",provider=provider,event="SessionStart",session_id=f"session-{token}",transcript_path=str(path))
            paths.append(path)
        return paths
    def test_time_trigger_once_repeat_and_interactive_arming(self):
        from datetime import datetime, timezone
        stamp = lambda seconds: datetime.fromtimestamp(seconds, timezone.utc).isoformat()
        self.register(4)
        once = self.node(1,"scheduled-trigger","--at",stamp(time.time()+3),"--text","wake up","--headless")
        manifest = wait(lambda:self.manifest(1,"Scheduled Trigger"))
        self.assertEqual(manifest["inputs"],[])
        self.assertEqual([p["id"] for p in manifest["outputs"]],["out"])
        self.connect(1,"out",4)
        event = wait(lambda:self.inbox(4))[0]
        self.assertEqual(event["text"],"wake up")
        self.assertEqual(event["kind"],"time.trigger")
        self.assertEqual(once.wait(timeout=5),0)
        self.assertEqual(len(self.inbox(4)),1)
        start = time.time()+3
        repeat = self.node(2,"scheduled-trigger","--every","1s","--from",stamp(start),"--until",stamp(start+3),"--headless")
        wait(lambda:self.manifest(2,"Scheduled Trigger")); self.connect(2,"out",5)
        self.assertEqual(repeat.wait(timeout=12),0)
        events = self.inbox(5)
        self.assertEqual(len(events),3)
        self.assertEqual([e["payload"]["sequence"] for e in events],[1,2,3])
        for i,e in enumerate(events):
            self.assertAlmostEqual(datetime.fromisoformat(e["payload"]["scheduled_at"]).timestamp(),start+i,places=2)
        ui = self.node(3,"scheduled-trigger","--every","1s",terminal=True)
        wait(lambda:"Paused" in ui.text()); self.connect(3,"out",6)
        self.assertEqual(self.inbox(6),[])
        ui.press("Ctrl+Enter")
        wait(lambda:self.inbox(6))
        self.assertIn("Armed",ui.text())
        ui.write("x") # Editing immediately pauses the clock.
        wait(lambda:"Paused" in ui.text())
        count = len(self.inbox(6)); time.sleep(1.2)
        self.assertEqual(len(self.inbox(6)),count)

    def test_filter_deadline_stops_loop_without_jq(self):
        from datetime import datetime, timezone
        self.register(1)
        deadline = time.time()+4
        node = self.node(2,"filter","--before",datetime.fromtimestamp(deadline,timezone.utc).isoformat(),"--headless")
        wait(lambda:self.manifest(2,"Filter"))
        self.connect(1,"out",2); self.connect(2,"matched",4)
        self.call(1,"graph.emit",output="out",text="continue",payload={"iteration":1})
        event = wait(lambda:self.inbox(4))[0]
        self.assertEqual(event["payload"]["iteration"],1)
        time.sleep(max(0,deadline-time.time())+.1)
        self.call(1,"graph.emit",output="out",text="stop",payload={"iteration":2})
        wait(lambda:not self.inbox(2))
        self.assertEqual(len(self.inbox(4)),1)
        self.assertIsNone(node.poll())

    def test_tcp_auth_fragmentation_large_payload_and_multiple_clients(self):
        self.assertEqual(self.raw("wrong","graph.list")["error"]["code"],"unauthorized")
        self.assertEqual(self.raw(1,"graph.list",version=99)["error"]["code"],"unsupported_version")
        self.register(1);self.connect(1,"out",4)
        large="message-"+"x"*300000
        result=self.raw(1,"graph.emit",{"output":"out","payload":{"text":large}},fragment=True)
        self.assertNotIn("error",result)
        event=self.inbox(4)[0];self.assertEqual(event["text"],large)
        self.assertEqual(self.inbox(5),[])
        self.call(4,"graph.ack",event_id=event["event_id"],status="delivered")
        self.assertEqual(self.inbox(4),[])
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda token:self.call(token,"graph.list"),range(1,5)))
        self.assertTrue(all(len(result["nodes"])==9 for result in results))
    def test_reader_gathers_permissions_preserves_prompt_and_rechecks_revocation(self):
        self.register(1);self.sessions()
        reader=self.node(4,"read-session-file","--last","2")
        wait(lambda:self.manifest(4,"Read Session File"))
        self.connect(1,"out",4);self.connect(2,"read",4);self.connect(3,"read",4);self.connect(4,"out",6)
        self.assertEqual(self.inbox(6),[]) # Read permission never triggers alone.
        self.call(1,"graph.emit",output="out",text="current prompt",payload={"custom":7})
        event=wait(lambda:self.inbox(6))[0]
        self.assertEqual(event["text"],"current prompt")
        self.assertEqual(event["payload"]["custom"],7)
        self.assertEqual([h["source"] for h in event["payload"]["history"]],["%2","%3"])
        self.assertEqual([len(h["messages"]) for h in event["payload"]["history"]],[2,2])
        self.assertEqual(event["origin"]["source"],"%1")
        self.call(1,"graph.disconnect",**{"from":"%3","to":"%4","from_port":"read","to_port":"in"})
        self.call(1,"graph.emit",output="out",text="next",payload={})
        events=wait(lambda:self.inbox(6) if len(self.inbox(6))==2 else None)
        self.assertEqual(len(events[1]["payload"]["history"]),1)
        self.assertEqual(events[1]["text"],"next")
        self.assertIsNone(reader.poll())
    def test_manual_prompt_and_reader_preview_read_now_conpty(self):
        self.sessions()
        reader=self.node(4,"read-session-file","--last","1",terminal=True)
        prompt=self.node(1,"manual-prompt",terminal=True)
        wait(lambda:self.manifest(4,"Read Session File"));manifest=wait(lambda:self.manifest(1,"Manual Prompt"))
        self.assertEqual(manifest["inputs"],[]);self.assertEqual(len(manifest["outputs"]),1)
        self.connect(1,"out",4);self.connect(2,"read",4);self.connect(3,"read",4);self.connect(4,"out",6)
        wait(lambda:"Read now" in reader.text())
        reader.press("F5") # Preview only
        wait(lambda:"Preview only" in reader.text())
        self.assertEqual(self.inbox(6),[])
        reader.write("\x1b[<0;28;3M\x1b[<0;28;3m") # Click Read now
        manual=wait(lambda:self.inbox(6))[0]
        self.assertIn("claude-2",manual["text"]);self.assertIn("codex-2",manual["text"])
        wait(lambda:"Prompt" in prompt.text())
        prompt.write("first line")
        prompt.press("Shift+Enter")
        prompt.write("second line")
        time.sleep(.3)
        self.assertEqual(len(self.inbox(6)),1)
        prompt.write("\r")
        events=wait(lambda:self.inbox(6) if len(self.inbox(6))==2 else None)
        self.assertEqual(events[1]["text"],"first line\nsecond line")
        from datetime import datetime
        offset = datetime.now().astimezone().strftime("%z")
        offset = offset[:3] + ":" + offset[3:]
        wait(lambda:"You" in prompt.text() and offset in prompt.text())
    def test_manual_prompt_through_godot_terminal_keyboard(self):
        self.call(1,"test.terminal.start")
        wait(lambda: "GFT_READY>" in json.dumps(self.call(1,"test.terminal.text")))
        command = '"' + CLI + '" node manual-prompt\r'
        self.call(1,"test.terminal.write",text=command)
        wait(lambda:self.manifest(1,"Manual Prompt"))
        self.connect(1,"out",6)
        self.call(1,"test.terminal.write",text="inside Godot")
        self.call(1,"test.terminal.enter",shift=True)
        self.call(1,"test.terminal.write",text="second line")
        self.assertEqual(self.inbox(6),[])
        self.call(1,"test.terminal.enter",shift=False)
        event=wait(lambda:self.inbox(6))[0]
        self.assertEqual(event["text"],"inside Godot\nsecond line")
        self.call(1,"test.terminal.write",text="\x03")

    def test_filter_inspector_and_parallel_real_tcp(self):
        self.register(1);self.register(2)
        parallel=self.node(3,"parallel","--once")
        wait(lambda:self.manifest(3,"Parallel"))
        filter_node=self.node(4,"filter","--headless","--condition","true","--once")
        wait(lambda:self.manifest(4,"Filter"))
        inspector=self.node(5,"payload-inspector","--json","--once")
        wait(lambda:self.manifest(5,"Payload Inspector"))
        self.connect(1,"out",3,"join");self.connect(2,"out",3,"join");self.connect(3,"combined",4);self.connect(4,"matched",5,"payload");self.connect(4,"matched",6)
        self.call(1,"graph.emit",output="out",payload={"text":"left"});self.assertEqual(self.inbox(6),[])
        self.call(2,"graph.emit",output="out",payload={"text":"right"})
        event=wait(lambda:self.inbox(6))[0]
        self.assertIn("left",event["text"]);self.assertIn("right",event["text"])
        for process in [parallel,filter_node,inspector]:
            process.wait(timeout=10);self.assertEqual(process.returncode,0)
        self.assertEqual(self.inbox(5),[])
    def test_reader_to_model_router_sends_only_original_prompt(self):
        requests=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                data=json.dumps({"answers":{"route":{"type":"choice","choice":"opus"}}}).encode()
                self.send_response(200);self.send_header("Content-Type","application/json");self.send_header("Content-Length",str(len(data)));self.end_headers();self.wfile.write(data)
        server=ThreadingHTTPServer(("127.0.0.1",0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            self.register(1);self.sessions()
            self.node(4,"read-session-file","--last","2");wait(lambda:self.manifest(4,"Read Session File"))
            config=self.folder/"router.json"
            config.write_text(json.dumps({"input":"{prompt: .text, history: .payload.history}"}),encoding="utf-8")
            router=self.node(5,"systemone","--headless","--once","--question","Choose model","--mode","choice","--config",str(config),"--outputs",json.dumps([{"id":"sonnet","description":"Routine"},{"id":"opus","description":"Complex"}]),"--endpoint",f"http://127.0.0.1:{server.server_port}",env={"OPENROUTER_API_KEY":"test-only"})
            wait(lambda:self.manifest(5,"SystemOne"))
            self.connect(1,"out",4);self.connect(2,"read",4);self.connect(3,"read",4);self.connect(4,"out",5,"evaluate");self.connect(5,"sonnet",6);self.connect(5,"opus",7)
            self.call(1,"graph.emit",output="out",text="Plan the migration",payload={})
            event=wait(lambda:self.inbox(7))[0]
            self.assertEqual(event["text"],"Plan the migration");self.assertEqual(self.inbox(6),[])
            self.assertEqual(requests[0]["state"]["prompt"],"Plan the migration");self.assertEqual(len(requests[0]["state"]["history"]),2)
            router.wait(timeout=10);self.assertEqual(router.returncode,0)
        finally:
            server.shutdown();server.server_close();thread.join()

if __name__ == "__main__": unittest.main(verbosity=2)
