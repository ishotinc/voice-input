#!/usr/bin/env python3
import json, os, pathlib, re, struct, sys, time, base64, subprocess
header=sys.stdin.buffer.read(4)
if len(header)!=4: sys.exit(0)
n=struct.unpack('<I',header)[0]
if n>1048576: sys.exit(1)
message=json.loads(sys.stdin.buffer.read(n))
code=message.get('code','')
joined=message.get('joined') is True and isinstance(code,str) and re.fullmatch('[a-z]{3}-[a-z]{4}-[a-z]{3}',code) is not None
observations=[]
for frame in (message.get('observations',[]) if isinstance(message.get('observations'),list) else [])[-6:]:
 if not isinstance(frame,dict) or not isinstance(frame.get('at'),(int,float)) or not 0 <= time.time()-frame['at'] < 10: continue
 rows=frame.get('participants',[])
 if not isinstance(rows,list) or len(rows)>100: continue
 clean=[]
 for row in rows:
  if not isinstance(row,dict) or not all(isinstance(row.get(k),str) and row[k] for k in ['id','name']): continue
  clean.append(dict(id=row['id'][:200],name=row['name'][:100],isSelf=row.get('isSelf') is True,speaking=row.get('speaking') is True))
 observations.append(dict(at=frame['at'],participants=clean,complete=frame.get('complete') is True and len(clean)==len(rows)))
base=pathlib.Path.home()/'.voice-input'/'meet-bridge'
base.mkdir(mode=0o700,parents=True,exist_ok=True)
shared_text = ''
shared_at = 0
frame = message.get('sharedFrame')
if joined and isinstance(frame, dict) and isinstance(frame.get('at'), (int,float)) and 0 <= time.time()-frame['at'] < 15 and isinstance(frame.get('image'), str) and len(frame['image']) <= 400000:
 try:
  previous = json.loads((base/'state.json').read_text()) if (base/'state.json').exists() else {}
  shared_at = frame['at']
  if previous.get('code') == code and previous.get('sharedScreenAt') == shared_at:
   pass
  else:
   data = base64.b64decode(frame['image'], validate=True)
   app = pathlib.Path.home()/'Applications/VoiceInput.app/Contents/MacOS/VoiceInput'
   result = subprocess.run([str(app),'--shared-screen-ocr',code,str(shared_at)],input=data,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=3)
   if result.returncode != 0: shared_at = 0
 except Exception:
  shared_text = ''
p=base/f'{os.getpid()}.tmp'
fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: json.dump(dict(sharedScreenAt=shared_at,waitingForParticipant=message.get('waitingForParticipant') is True,extensionVersion=message.get('extensionVersion','')[:20] if isinstance(message.get('extensionVersion'),str) else '',observations=observations if joined else [],joined=joined,code=code if joined else '',timestamp=time.time(),selfName=message.get('selfName','')[:100] if isinstance(message.get('selfName'),str) and joined else '',title=message.get('title','')[:200] if isinstance(message.get('title'),str) and joined else ''),f)
os.replace(p,base/'state.json')
reply=b'{"ok":true}'
sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply);sys.stdout.buffer.flush()
