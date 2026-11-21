#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Owned Chromium authentication rejection, workspace routing and profile isolation.

Uses local-capability authentication; Windows reaches loopback through SSH.
Workspaces are routing contexts, not separate principals: a holder of the server
capability can deliberately connect to another workspace. No remote OPAQUE claim.
"""
import json
from pathlib import Path
import time
import websocket
from test_chromium_platform_stress import main, Client, evaluate, eventually


class Workspace:
    def __init__(self, descriptor, name):
        self.client = Client(descriptor, workspace=name, chromium_video=['hevc','h264'])
        self.pane = self.client.topology['panes'][0]['id']
        self.request = 0
    def call(self, method, **params):
        self.request += 1
        self.client.action('rpc', self.pane, request=self.request, method=method, params=params)
        self.client.until(lambda: any(v.get('request') == self.request for v in self.client.messages))
        reply = next(v for v in self.client.messages if v.get('request') == self.request)
        self.client.messages.clear()
        return reply
    def rpc(self, method, **params):
        reply = self.call(method, **params)
        assert reply['type']=='ack', reply
        return reply['result']
    def page(self, url):
        page = self.rpc('chromium.create',url=url,profile='')['chromium']; sid=int(page[1:])
        self.client.until(lambda: any(b['id']==sid and b['state'].get('chromiumId',-1)>0 for b in self.client.topology.get('chromiums',[])))
        eventually(lambda: evaluate(self.rpc,page,'document.title')=='Isolation fixture','Test origin did not load')
        return page,sid
    def close(self): self.client.ws.close()


def exercise(matrix,out,descriptor):
    if matrix.args.platform=='windows':
        matrix.copy(out/'live-fixture.json',matrix.remote+'/'+out.name+'/fixture.json',download=True)
        fixture=json.loads((out/'live-fixture.json').read_text())
    else: fixture=json.loads((out/'owner/fixture.json').read_text())
    url=fixture['origin_url']; results={}; workspaces=[]
    def save(name,value=True):
        results[name]=value;(out/'isolation.json').write_text(json.dumps(results,indent=2));print(out.name,name,'pass',flush=True)
    def workspace(name):
        w=Workspace(descriptor,name);workspaces.append(w);return w
    try:
        alpha=workspace('isolation-alpha');beta=workspace('isolation-beta')
        a,aid=alpha.page(url);b,bid=beta.page(url)
        assert evaluate(alpha.rpc,a,"localStorage.setItem('private','alpha');document.cookie='private=alpha; path=/';window.identity='alpha';document.body.style.background='rgb(20,160,80)';true")
        assert evaluate(beta.rpc,b,"[localStorage.getItem('private'),document.cookie]")==[None,'']
        assert evaluate(beta.rpc,b,"localStorage.setItem('private','beta');document.cookie='private=beta; path=/';window.identity='beta';true")
        own2,sid2=alpha.page(url)
        assert evaluate(alpha.rpc,own2,"[localStorage.getItem('private'),document.cookie]")==[None,'']
        assert evaluate(alpha.rpc,a,"[localStorage.getItem('private'),document.cookie]")==['alpha','private=alpha']
        save('temporary_profile_storage',{'separate_workspaces':True,'same_workspace_separate_hosts':True})
        alpha.client.action('subscribe',sessions=[aid]);beta.client.action('subscribe',sessions=[aid,bid])
        alpha.client.until(lambda: aid in alpha.client.frames)
        beta.client.until(lambda: bid in beta.client.frames)
        assert alpha.client.frames[aid]['format'] in ('hevc','h264')
        assert beta.client.frames[bid]['format'] in ('hevc','h264')
        deadline=time.monotonic()+3
        for c in [alpha.client,beta.client]:c.ws.settimeout(.1)
        while time.monotonic()<deadline:
            for c in [alpha.client,beta.client]:
                try:c.receive()
                except websocket.WebSocketTimeoutException:pass
            assert aid not in beta.client.frames
            assert not any(x['id'] in (aid,sid2) for x in beta.client.topology.get('chromiums',[]))
            assert not any(x['id']==bid for x in alpha.client.topology.get('chromiums',[]))
        for c in [alpha.client,beta.client]:c.ws.settimeout(5)
        save('workspace_topology_and_subscription')
        ticket=alpha.rpc('chromium.command',chromium=a,action='cdp',args={'method':'Runtime.evaluate','params':{'expression':'window.identity','returnByValue':True}})['ticket']
        attempts=[('chromium.command',dict(chromium=a,action='tab-navigate',args={'text':'about:blank'})),
            ('chromium.result',dict(chromium=a,ticket=ticket)),
            ('chromium.input',dict(chromium=a,event={'method':'Input.dispatchMouseEvent','params':{'type':'mouseMoved','x':1,'y':1}})),
            ('chromium.close',dict(chromium=a))]
        for method,params in attempts:
            reply=beta.call(method,**params);assert reply['type']!='ack',(method,reply)
        answer=eventually(lambda: alpha.rpc('chromium.result',chromium=a,ticket=ticket),'Owner lost command result')
        assert answer['result']['result']['value']=='alpha',answer
        save('cross_workspace_commands_and_result_ownership',[m for m,_ in attempts])
        token=descriptor['local']['token']
        bad=[('wrong_token',{'type':'auth_local','version':1,'token':'not-a-capability'}),
            ('wrong_version',{'type':'auth_local','version':2,'token':token}),
            ('missing_version',{'type':'auth_local','token':token}),
            ('unauthenticated_subscribe',{'type':'subscribe','sessions':[aid]}),
            ('unauthenticated_rpc',{'type':'rpc','session':alpha.pane,'request':1,'method':'chromium.list','params':{}})]
        for name,attempt in bad:
            ws=websocket.create_connection(descriptor['url'],timeout=5)
            try:
                ws.send(json.dumps(attempt));reply=ws.recv()
                assert reply in ('',b''),(name,'Rejected connection exposed a message')
            finally:ws.close()
        assert evaluate(alpha.rpc,a,'window.identity')=='alpha'
        assert evaluate(beta.rpc,b,'window.identity')=='beta'
        save('authentication_rejection_while_streaming',[name for name,_ in bad])
        alpha.close();workspaces.remove(alpha)
        fresh=workspace('isolation-alpha')
        fresh.client.action('subscribe',sessions=[aid]);fresh.client.until(lambda: aid in fresh.client.frames)
        assert evaluate(fresh.rpc,a,"[window.identity,localStorage.getItem('private'),document.cookie]")==['alpha','alpha','private=alpha']
        assert evaluate(beta.rpc,b,"[window.identity,localStorage.getItem('private'),document.cookie]")==['beta','beta','private=beta']
        save('reconnect_retains_own_document_and_storage')
    finally:
        for w in workspaces:w.close()


if __name__=='__main__': raise SystemExit(main(exercise,__doc__,test_origin=True))
