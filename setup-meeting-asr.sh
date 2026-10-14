#!/bin/bash
# Full Whisper for meeting accuracy; downloaded locally, not included in git/app.
set -euo pipefail
umask 077
DEST="${VOICEINPUT_MODELS:-$HOME/.voice-input/models}"
mkdir -p "$DEST"
TEMP=$(mktemp "$DEST/.large-v3-XXXXXX")
trap 'rm -f "$TEMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$TEMP" 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin'
python3 - "$TEMP" <<'CHECK'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as stream:
    for block in iter(lambda: stream.read(1048576), b''):
        h.update(block)
if h.hexdigest() != 'd75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1':
    raise SystemExit('Whisper checksum mismatch')
CHECK
mv "$TEMP" "$DEST/ggml-large-v3-q5_0.bin"
printf 'Meeting Whisper large-v3 ready.\n'
