#!/bin/bash
set -euo pipefail
export LC_ALL=en_US.UTF-8
ROOT="${FASTOCR_SPEECH_ROOT:-$HOME/Library/Application Support/FastOCR/Speech}"
mkdir -p "$ROOT"
MODEL="$ROOT/ggml-small-q5_1.bin"
CHECKSUM=ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb
if [ -f "$MODEL" ] && echo "$CHECKSUM  $MODEL" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo '语音模型已就绪。'; exit 0
fi
TEMP="$(mktemp "$ROOT/model.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
echo '正在下载本地中英日语音模型（约 181 MiB）…'
curl -fL --retry 3 --connect-timeout 20 --max-time 900 --silent --show-error \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin -o "$TEMP"
echo "$CHECKSUM  $TEMP" | shasum -a 256 -c -
mv "$TEMP" "$MODEL"
echo '语音模型准备完成，识别过程无需联网。'
