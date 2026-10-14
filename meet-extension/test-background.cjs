const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync(__dirname+'/background.js','utf8');
const tick = () => new Promise(resolve=>setImmediate(resolve));
(async()=>{
 let receive, removed, installed, started, fail=false;
 const sent=[], badges=[], injected=[];
 const chrome={runtime:{onMessage:{addListener:f=>receive=f},onInstalled:{addListener:f=>installed=f},onStartup:{addListener:f=>started=f},sendNativeMessage:async(_,message)=>{sent.push(message);if(fail)throw Error('host unavailable');return {ok:true};}},
 tabs:{onRemoved:{addListener:f=>removed=f},query:async()=>[{id:4},{id:5}]},
 scripting:{executeScript:async request=>injected.push(request)},
 action:{setBadgeText:async ({text})=>badges.push(text),setBadgeBackgroundColor:async()=>{},setTitle:async()=>{}}};
 vm.runInNewContext(source,{chrome,console});
 receive({joined:true,code:'abc-defg-hij'},{tab:{id:4},url:'https://meet.google.com/abc-defg-hij'}); await tick();
 assert.equal(sent.at(-1).joined,true);assert.equal(badges.at(-1),'ON'); console.log('PASS: Meet参加をMacへ通知');
 removed(4); await tick();assert.equal(sent.at(-1).joined,false);console.log('PASS: タブ終了で停止通知');
 fail=true;receive({joined:false},{tab:{id:4},url:'https://meet.google.com/home'});await tick();assert.equal(badges.at(-1),'!');console.log('PASS: 接続失敗を隠さず表示');
 installed();await tick();assert.equal(injected.length,2);assert.deepEqual(Array.from(injected[0].files),['content.js']);console.log('PASS: 更新後にMeetタブへ再注入');
 started();await tick();assert.equal(injected.length,4);console.log('PASS: ブラウザ再起動時に再接続');
 const count=sent.length;receive({joined:true},{tab:{id:9},url:'https://example.com/'});await tick();assert.equal(sent.length,count);console.log('PASS: Meet以外の送信元を拒否');
})().catch(error=>{console.error(error);process.exitCode=1;});
