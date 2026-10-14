const sessions = new Map();
let publishing = false;
let dirty = false;
function badge(text, title, color) {
  void chrome.action.setBadgeText({text}).catch(() => {});
  void chrome.action.setBadgeBackgroundColor({color}).catch(() => {});
  void chrome.action.setTitle({title}).catch(() => {});
}
chrome.runtime.onMessage.addListener((message, sender) => {
  if (!sender.tab || !sender.url?.startsWith('https://meet.google.com/')) return;
  sessions.set(sender.tab.id, {joined:message.joined === true, waitingForParticipant:message.waitingForParticipant === true, participantCount:message.participantCount, code:message.code,
    sharedFrame:message.sharedFrame && typeof message.sharedFrame.image === "string" && message.sharedFrame.image.length <= 400000 ? message.sharedFrame : null,
    selfName:typeof message.selfName === 'string' ? message.selfName.slice(0,100) : '',
    title:typeof message.title === 'string' ? message.title.slice(0,200) : '',
    observations:Array.isArray(message.observations) ? message.observations.slice(-6) : [], at:Date.now()});
  void publish();
});
chrome.tabs.onRemoved.addListener(id => { sessions.delete(id); void publish(); });
async function publish() {
  dirty = true;
  if (publishing) return;
  publishing = true;
  try {
    while (dirty) {
      dirty = false;
      const active = [...new Map([...sessions.values()].filter(s => s.joined && Date.now()-s.at < 7000).map(s => [s.code, s])).values()];
      const current = active.length === 1 ? active[0] : null;
      const waiting = [...sessions.values()].some(s => s.waitingForParticipant && Date.now()-s.at < 7000);
      try {
        const reply = await chrome.runtime.sendNativeMessage('jp.ishot.voiceinput.meet', {
          extensionVersion:'1.1.4', waitingForParticipant:!current && waiting, joined:!!current, code:current?.code || '', title:current?.title || '',
          sharedFrame:current?.sharedFrame || null, selfName:current?.selfName || '', observations:current?.observations || []});
        if (reply?.ok !== true) throw Error('Native host did not acknowledge');
        badge(active.length > 1 ? '!' : current ? 'ON' : waiting ? 'WAIT' : '',
          active.length > 1 ? 'VoiceInput Meet：複数会議を検出。録音対象を選べません' :
          current ? 'VoiceInput Meet：参加をMacへ通知済み（録音状態はメニューバーで確認）' :
          waiting ? 'VoiceInput Meet：相手の入室待ち・まだ録音していません' : 'VoiceInput Meet：Macへの接続正常・会議参加待ち', active.length > 1 ? '#b45309' : '#15803d');
      } catch (_) {
        badge('!', 'VoiceInput Meet：Macへ接続できません。VoiceInputの起動と連携設定を確認してください', '#b91c1c');
      }
    }
  } finally { publishing = false; }
}
async function reconnectTabs() {
  try {
    const tabs = await chrome.tabs.query({url:'https://meet.google.com/*'});
    for (const tab of tabs) {
      if (!Number.isInteger(tab.id)) continue;
      try { await chrome.scripting.executeScript({target:{tabId:tab.id}, files:['content.js']}); }
      catch (_) { /* Navigating/closed tabs receive their declarative script later. */ }
    }
  } catch (_) { badge('!', 'VoiceInput Meet：Meetのタブを再読み込みしてください', '#b45309'); }
}
chrome.runtime.onInstalled.addListener(() => { void reconnectTabs(); });
chrome.runtime.onStartup.addListener(() => { void reconnectTabs(); });
