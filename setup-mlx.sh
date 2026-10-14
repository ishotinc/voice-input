#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v uv >/dev/null || { echo 'uv が必要です。インストールしてから再実行してください。'; exit 1; }
RUNTIME="$HOME/.voice-input/mlx-runtime"
if [ ! -x "$RUNTIME/bin/python" ]; then uv venv --python 3.12 "$RUNTIME"; fi
uv pip install --python "$RUNTIME/bin/python" -r benchmarks/requirements-mlx-lock.txt
"$RUNTIME/bin/python" - <<'PY'
from pathlib import Path
from huggingface_hub import snapshot_download
target = Path.home()/'.voice-input/mlx-models/large-v3-turbo'
snapshot_download('mlx-community/whisper-large-v3-turbo', local_dir=str(target),
                  allow_patterns=['*.json', '*.npz', '*.safetensors'])
print('MLXモデル準備完了。アプリ設定の useMLXForDictation で有効化できます。')
PY
