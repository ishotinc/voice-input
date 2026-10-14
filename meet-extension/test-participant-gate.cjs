const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync(__dirname+'/content.js','utf8');
let tick, now=10000, inCall=true, count='1', visible=true, last;
const location={pathname:'/abc-defg-hij'};
const leave={getClientRects:()=>inCall?[{}]:[],getAttribute:()=> '通話から退出'};
const people={getClientRects:()=>visible?[{}]:[],getAttribute:key=>key==='aria-label'?'ユーザー':null,get innerText(){return count;}};
const context=vm.createContext({chrome:{runtime:{id:'test',sendMessage:message=>{last=message;return Promise.resolve();}}},location,
 document:{querySelectorAll:selector=>selector==='button,[role="button"]'?[leave,people]:[],querySelector:()=>null,getElementById:()=>null},
 setInterval:f=>{tick=f;return 1;},clearInterval:()=>{},Date:{now:()=>now},console});
vm.runInContext(source,context);
assert.equal(last.joined,false);assert.equal(last.waitingForParticipant,true);console.log('PASS: 自分1人では録音開始しない');
for(let i=0;i<3600;i++){now+=1000;tick();assert.equal(last.joined,false);}
console.log('PASS: 1時間待機しても録音開始しない');
count='';tick();assert.equal(last.joined,false);console.log('PASS: 人数不明なら開始しない');
count='2';visible=false;tick();assert.equal(last.joined,false);console.log('PASS: 非表示の人数表示は根拠にしない');
visible=true;tick();assert.equal(last.joined,true);assert.equal(last.waitingForParticipant,false);console.log('PASS: 相手が入室して2人になれば開始');
count='1';tick();assert.equal(last.joined,true);console.log('PASS: 相手が一時退出しても録音継続');
vm.runInContext(source,context);assert.equal(last.joined,true);console.log('PASS: 再注入で開始済み状態を失わない');
inCall=false;tick();assert.equal(last.joined,false);now+=2000;inCall=true;tick();assert.equal(last.joined,true);console.log('PASS: 一時的なDOM欠落後に録音状態が復帰');
inCall=false;tick();now+=7000;tick();inCall=true;tick();assert.equal(last.joined,false);console.log('PASS: 退出後に1人で再参加したら待機に戻る');
count='2';tick();assert.equal(last.joined,true);location.pathname='/def-hijk-lmn';count='1';tick();assert.equal(last.joined,false);console.log('PASS: 別の会議へ録音開始条件を持ち越さない');
inCall=false;count='2';tick();assert.equal(last.joined,false);console.log('PASS: 自分が参加前なら人数2でも開始しない');
