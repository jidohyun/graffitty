/** Freeze the analysed peaking filters and level envelopes with Web Audio.
 * Usage: npm ci --prefix music-tools && node music-tools/bake.mjs
 * Run from the composition directory. Output is stereo 48 kHz float PCM.
 */
import {chromium} from 'playwright';
import {readFileSync,createWriteStream} from 'node:fs';
import {createServer} from 'node:http';
import {resolve} from 'node:path';
const root=process.cwd();
const profile=JSON.parse(readFileSync('music-profile.json','utf8'));
const server=createServer((req,res)=>{
  if(req.url==='/'){res.end('<html></html>');return;}
  if(req.url==='/music'){res.end(readFileSync(resolve(root,profile.source)));return;}
  res.writeHead(404);res.end();
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({channel:'chrome',headless:true});
const output=createWriteStream('assets/music/bed.f32');
try {
 const page=await browser.newPage();
 await page.exposeFunction('writePCM',b64=>new Promise((resolve,reject)=>output.write(Buffer.from(b64,'base64'),e=>e?reject(e):resolve())));
 await page.goto(`http://127.0.0.1:${server.address().port}/`);
 await page.evaluate(async profile=>{
  const context=new OfflineAudioContext(2,Math.round(profile.duration*48000),48000);
  const audio=await context.decodeAudioData(await (await fetch('/music')).arrayBuffer());
  const source=context.createBufferSource();source.buffer=audio;
  let previous=source;
  for(const spec of profile['data-fx-chain'].nodes){
   if(spec.enabled===false)continue;
   const node=spec.type==='peaking'?context.createBiquadFilter():context.createGain();
   if(spec.type==='peaking'){
    node.type='peaking';node.frequency.value=spec.params.frequency;node.Q.value=spec.params.q;
   } else if(spec.type!=='gain')throw new Error(`Unsupported effect ${spec.type}`);
   const lane=profile['data-automation'].lanes.find(l=>l.target===`fx.${spec.id}.gain`);
   const value=db=>spec.type==='gain'?Math.pow(10,db/20):db;
   if(lane){
    // 10 ms samples interpolate in dB before converting the gain to amplitude.
    const pts=lane.points;let i=0;
    node.gain.setValueAtTime(value(pts[0].v),0);
    for(let t=.01;t<=profile.duration;t+=.01){
     while(i+1<pts.length&&pts[i+1].t<t)i++;
     const a=pts[i],b=pts[Math.min(i+1,pts.length-1)];
     const f=b.t>a.t?Math.max(0,Math.min(1,(t-a.t)/(b.t-a.t))):0;
     node.gain.linearRampToValueAtTime(value(a.v+(b.v-a.v)*f),t);
    }
   }else node.gain.value=value(spec.params.gain);
   previous.connect(node);previous=node;
  }
  previous.connect(context.destination);source.start();
  const rendered=await context.startRendering();
  const left=rendered.getChannelData(0),right=rendered.getChannelData(1);
  for(let start=0;start<left.length;start+=65536){
   const length=Math.min(65536,left.length-start),data=new Float32Array(length*2);
   for(let i=0;i<length;i++){data[2*i]=left[start+i];data[2*i+1]=right[start+i];}
   const bytes=new Uint8Array(data.buffer);let binary='';
   for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
   await window.writePCM(btoa(binary));
  }
 },profile);
}finally{await browser.close();server.close();await new Promise(r=>output.end(r));}
