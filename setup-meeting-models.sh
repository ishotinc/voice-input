#!/bin/bash
# Optional local speaker models. Downloaded separately; never bundled in the app/repository.
set -euo pipefail
umask 077
RUNTIME="${VOICEINPUT_MEETING_RUNTIME:-$HOME/.voice-input/meeting-runtime}"
MODELS="${VOICEINPUT_MEETING_MODELS:-$HOME/.voice-input/meeting-models}"
PYTHON="${VOICEINPUT_PYTHON:-python3}"
mkdir -p "$MODELS"
if [[ ! -x "$RUNTIME/bin/python" ]]; then
  "$PYTHON" -m venv "$RUNTIME"
fi
"$RUNTIME/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: 'sherpa-onnx==1.13.8' 'numpy==1.26.4' 'soundfile==0.13.1' 'cffi==2.0.0' 'pycparser==2.23'
STAGING=$(mktemp -d "$MODELS/.download-XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$STAGING/silero_vad.onnx" 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
# Older official release assets have no publisher-supplied digest. These SHA256
# values pin the actual upstream HTTPS assets inspected on 2026-09-15.
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$STAGING/segmentation.tar.bz2" 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2'
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$STAGING/embedding.onnx" 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx'
"$RUNTIME/bin/python" - "$STAGING" "$MODELS" <<'PY'
import hashlib, pathlib, shutil, sys, tarfile
staging, models = map(pathlib.Path, sys.argv[1:])
expected = {
 'silero_vad.onnx': '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
 'segmentation.tar.bz2': '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488',
 'embedding.onnx': '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b',
}
for name, checksum in expected.items():
 if hashlib.sha256((staging / name).read_bytes()).hexdigest() != checksum:
  raise SystemExit('Model checksum failed: ' + name)
# Extract only two expected regular files, not arbitrary archive paths/scripts.
with tarfile.open(staging / 'segmentation.tar.bz2', 'r:bz2') as archive:
 for source, dest in [('model.onnx', 'segmentation.onnx'), ('LICENSE', 'SEGMENTATION-LICENSE')]:
  member = archive.getmember('sherpa-onnx-pyannote-segmentation-3-0/' + source)
  if not member.isfile():
   raise SystemExit('Unexpected archive member')
  with archive.extractfile(member) as data, (staging / dest).open('wb') as output:
   shutil.copyfileobj(data, output)
for name in ['silero_vad.onnx', 'segmentation.onnx', 'embedding.onnx', 'SEGMENTATION-LICENSE']:
 (staging / name).replace(models / name)
(models / 'MODEL-SOURCES.txt').write_text('''Speech detection: Silero VAD (sherpa-onnx official export); local inference, separately downloaded.
https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html
Inference library: sherpa-onnx 1.13.8 (Apache-2.0)
https://github.com/k2-fsa/sherpa-onnx
Segmentation: pyannote segmentation 3.0, upstream archive includes MIT license (SEGMENTATION-LICENSE).
https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models
Embedding: 3D-Speaker ERes2Net, project licensed Apache-2.0.
https://github.com/modelscope/3D-Speaker
https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
Models are downloaded for local inference and are not included in VoiceInput source or app distribution.
''')
PY
"$RUNTIME/bin/python" -c 'import sherpa_onnx, soundfile, numpy; print("Meeting speaker models and runtime are ready.")'
