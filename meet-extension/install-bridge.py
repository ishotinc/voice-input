import base64, hashlib, json, pathlib, shutil, sys
source=pathlib.Path(__file__).resolve().parent
manifest=json.loads((source/'manifest.json').read_text())
extid=''.join(chr(97+int(c,16)) for c in hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32])
dest=pathlib.Path.home()/'.voice-input'/'meet-extension'
dest.mkdir(parents=True,exist_ok=True,mode=0o700)
for name in ['manifest.json','content.js','background.js','native-host.py']: shutil.copy2(source/name,dest/name)
host=dest/'native-host.py'
python=pathlib.Path.home()/'.voice-input/meeting-runtime/bin/python'
if not python.exists(): raise SystemExit('会議用Python環境が必要です')
host.write_text('#!'+str(python)+'\n'+'\n'.join(host.read_text().splitlines()[1:])+'\n');host.chmod(0o700)
registry=pathlib.Path.home()/'Library/Application Support/Google/Chrome/NativeMessagingHosts'
registry.mkdir(parents=True,exist_ok=True)
p=registry/'jp.ishot.voiceinput.meet.json'
p.write_text(json.dumps(dict(name='jp.ishot.voiceinput.meet',description='VoiceInput Meet status bridge',path=str(host),type='stdio',allowed_origins=['chrome-extension://'+extid+'/'])))
p.chmod(0o600)
print(dest)
