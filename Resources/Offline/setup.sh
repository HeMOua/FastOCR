#!/bin/bash
set -euo pipefail
export LC_ALL=en_US.UTF-8
ROOT="${FASTOCR_OFFLINE_ROOT:-$HOME/Library/Application Support/FastOCR/Offline}"
UV="$(command -v uv || true)"
for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
  if [ -z "$UV" ] && [ -x "$candidate" ]; then UV="$candidate"; fi
done
if [ -z "$UV" ]; then
  echo '需要先安装 uv，再点击准备离线模型。安装说明：https://docs.astral.sh/uv/getting-started/installation/' >&2
  exit 1
fi
mkdir -p "$ROOT"
if [ ! -x "$ROOT/runtime/bin/python" ]; then
  "$UV" venv --managed-python --python 3.11 "$ROOT/runtime"
fi
"$UV" pip install --python "$ROOT/runtime/bin/python" 'ctranslate2==4.6.0' 'sentencepiece==0.2.1'
"$ROOT/runtime/bin/python" "$(dirname "$0")/install_models.py" "$ROOT"
