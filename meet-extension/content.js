// Only the visible meeting title and call state are sent to the local app.
(() => {
// One live reporter per document, including manual reinjection after an update.
try {
  if (typeof globalThis.__voiceInputMeetStop === "function") globalThis.__voiceInputMeetStop();
} catch (_) { /* The previous extension world may already be invalidated. */ }
let reportTimer;
let stopped = false;
let sharedFrame = null;
let lastShareCapture = 0;
const observations = [];
// Keep an already-started call through reinjection and temporary participant departures.
const recordingGate = globalThis.__voiceInputMeetRecordingGate || {code:'', started:false, absentSince:null};
globalThis.__voiceInputMeetRecordingGate = recordingGate;
function readyToRecord(inCall, code, presence) {
  if (recordingGate.code !== code) {
    recordingGate.code = code; recordingGate.started = false; recordingGate.absentSince = null;
  }
  if (!inCall) {
    if (recordingGate.absentSince === null) recordingGate.absentSince = Date.now();
    if (Date.now() - recordingGate.absentSince >= 6000) recordingGate.started = false;
    return false;
  }
  recordingGate.absentSince = null;
  const otherJoined = presence.count !== null ? presence.count >= 2 :
    presence.participants.some(p => p.isSelf) && presence.participants.some(p => !p.isSelf);
  if (otherJoined) recordingGate.started = true;
  return recordingGate.started;
}
function stop() {
  stopped = true;
  try { clearInterval(reportTimer); } catch (_) {}
  try { observations.length = 0; sharedFrame = null; } catch (_) {}
}
globalThis.__voiceInputMeetStop = stop;
function invalidated(error) { return /Extension context invalidated/i.test(String(error)); }
function readParticipants() {
  const participants = [];
  const seen = new Set();
  for (const tile of document.querySelectorAll('main [data-participant-id]')) {
    if (!tile.getClientRects().length) continue;
    const id = tile.getAttribute('data-participant-id');
    const name = [...tile.querySelectorAll('span.notranslate')].map(e => e.textContent.trim()).find(Boolean);
    if (!id || !name || seen.has(id)) continue;
    seen.add(id);
    const labels = [...tile.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label') || '');
    const isSelf = labels.some(l => /^(背景とエフェクト|Backgrounds and effects)$/.test(l));
    const speaking = labels.some(l => /^(?:発話中|発言中|Speaking|Talking)$|(?:が発話中|が発言中| is speaking)$/i.test(l));
    participants.push({id:id.slice(0,200), name:name.slice(0,100), isSelf, speaking});
  }
  // The self label can be in the open people panel instead of the video tile.
  for (const row of document.querySelectorAll('[role="listitem"][aria-label]')) {
    if (!row.getClientRects().length || !/[（(](?:あなた|自分|You)[）)]/i.test(row.textContent)) continue;
    const matches = participants.filter(p => p.name === row.getAttribute('aria-label'));
    if (matches.length === 1) matches[0].isSelf = true;
  }
  const countButton = [...document.querySelectorAll('button,[role="button"]')].find(e => e.getClientRects().length > 0 && /^(ユーザー|People)$/.test(e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' ').trim()));
  const text = (countButton?.innerText || '').trim();
  const count = /^[0-9]+$/.test(text) && Number(text) >= 1 && Number(text) <= 10000 ? Number(text) : null;
  return {participants:participants.slice(0,100), count, complete:count !== null && count === participants.length};
}
// Fail closed: never sample an ordinary webcam tile. Only explicitly marked presentations.
function readSharedFrame(enabled) {
  if (!enabled) { sharedFrame = null; lastShareCapture = 0; return null; }
  const videos = [...document.querySelectorAll('video')].filter(video => {
    if (!video.getClientRects().length || video.videoWidth < 320 || video.videoHeight < 180) return false;
    let node = video;
    for (let depth = 0; node && depth < 7; depth++, node = node.parentElement) {
      if (node.getAttribute('data-is-presentation') === 'true' || node.getAttribute('data-presentation-id')) return true;
      const label = node.getAttribute('aria-label') || '';
      if (/(?:共有画面|共有された画面|画面共有のコンテンツ|shared screen|presentation by|presented by)/i.test(label)) return true;
    }
    return false;
  });
  if (videos.length !== 1) { sharedFrame = null; return null; }
  if (Date.now() - lastShareCapture < 8000) return sharedFrame;
  lastShareCapture = Date.now();
  try {
    const video = videos[0], canvas = document.createElement('canvas');
    const ratio = Math.min(1, 1600 / video.videoWidth, 1000 / video.videoHeight);
    canvas.width = Math.round(video.videoWidth * ratio); canvas.height = Math.round(video.videoHeight * ratio);
    canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
    const image = canvas.toDataURL('image/jpeg', 0.65).split(',')[1];
    sharedFrame = image.length <= 400000 ? {at:Date.now()/1000, image} : null;
  } catch (_) { sharedFrame = null; }
  return sharedFrame;
}
function reportOnce() {
  // Reloading the extension invalidates scripts in already-open Meet tabs.
  if (!chrome.runtime?.id) { stop(); return; }
  const code = location.pathname.slice(1);
  const joined = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(code) && [...document.querySelectorAll('button,[role="button"]')].some(el => {
    const label = el.getAttribute('aria-label') || el.getAttribute('data-tooltip') || el.textContent || '';
    return el.getClientRects().length > 0 && /通話から退出|通話を終了|会議から退出|Leave call|Leave the call|End call/i.test(label);
  });
  const heading = document.querySelector('h1');
  const rawTitle = (heading?.textContent || '').trim();
  const title = rawTitle && rawTitle !== code && !/^(Google Meet|Meet|会議|ミーティング)$/.test(rawTitle) ? rawTitle.slice(0,200) : '';
  let selfName = '';
  const markedSelf = document.querySelector('[data-self-name]');
  if (markedSelf) selfName = (markedSelf.getAttribute('data-self-name') || '').trim();
  if (!selfName) {
    for (const el of document.querySelectorAll('[aria-label]')) {
      const label = el.getAttribute('aria-label') || '';
      const match = label.match(/^(.{1,100})[（(](?:あなた|自分|You|you)[）)]$/);
      if (match && el.getClientRects().length) { selfName = match[1].trim(); break; }
    }
  }
  const presence = readParticipants();
  const recordingReady = readyToRecord(joined, code, presence);
  const own = presence.participants.filter(p => p.isSelf);
  if (own.length === 1) selfName = own[0].name;
  if (joined) {
    observations.push({at:Date.now()/1000, ...presence});
    while (observations.length > 6) observations.shift();
  } else observations.length = 0;
  try {
    chrome.runtime.sendMessage({joined:recordingReady, inCall:joined, waitingForParticipant:joined && !recordingReady, participantCount:presence.count, sharedFrame:readSharedFrame(recordingReady), code, title, selfName:selfName.slice(0,100), observations}).catch(error => { if (invalidated(error)) stop(); });
  } catch (error) {
    if (invalidated(error)) { stop(); return; }
    throw error;
  }
}
function report() {
  if (stopped) return;
  // Accessing runtime.id itself may throw after extension reload. Include every
  // runtime access, not just sendMessage, in the invalidation boundary.
  try { reportOnce(); }
  catch (error) { if (invalidated(error)) stop(); else console.warn('VoiceInput Meet status unavailable:', error); }
}
try {
  reportTimer = setInterval(report, 1000);
  report();
} catch (error) { stop(); }

})();
