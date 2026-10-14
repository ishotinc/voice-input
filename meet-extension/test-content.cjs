const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync(__dirname + '/content.js', 'utf8');
async function run(mode) {
  let ticks, cleared = 0, sent = 0;
  const runtime = {id:'test', sendMessage() {
    sent++;
    if (mode === 'sendThrow') throw Error('Extension context invalidated.');
    return mode === 'reject' ? Promise.reject(Error('Extension context invalidated.')) : Promise.resolve();
  }};
  if (mode === 'getter') Object.defineProperty(runtime,'id',{get(){throw Error('Extension context invalidated.');}});
  if (mode === 'missing') runtime.id = undefined;
  const context = vm.createContext({chrome:{runtime}, location:{pathname:'/home'},
    document:{querySelectorAll:()=>[],querySelector:()=>null},
    setInterval:f => {ticks=f;return 1;}, clearInterval:()=>{ cleared++; if(mode==='clearThrow') throw Error('Extension context invalidated.'); }, console});
  if (mode === 'oldStop') context.__voiceInputMeetStop = () => { throw Error('Extension context invalidated.'); };
  if (mode === 'clearThrow') runtime.id = undefined;
  vm.runInContext(source, context);
  await Promise.resolve(); await Promise.resolve();
  ticks();
  if (['healthy','oldStop'].includes(mode)) { assert.equal(sent,2); assert.equal(cleared,0); }
  else { assert.ok(cleared >= 1); assert.equal(sent, ['reject','sendThrow'].includes(mode) ? 1 : 0); }
  console.log('PASS:',mode);
}
(async () => {
  for (const mode of ['healthy','getter','missing','sendThrow','reject','oldStop','clearThrow']) await run(mode);
})().catch(error => { console.error(error); process.exitCode=1; });
