#!/bin/bash
set -euo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
SOURCE="$PWD/.build/speech-source"
ARCHIVE="$SOURCE/whisper-v1.9.3.tar.gz"
mkdir -p "$SOURCE"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --retry 3 --connect-timeout 20 --max-time 300 \
    https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.3 -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "1650f884effba487025143bd8facd2f9fb40a83b3737a732803c67a8d659d9c0  $ARCHIVE" | shasum -a 256 -c -
if [ ! -f "$SOURCE/whisper.cpp-1.9.3/CMakeLists.txt" ]; then tar -xzf "$ARCHIVE" -C "$SOURCE"; fi
if command -v cmake >/dev/null 2>&1; then
  CMAKE=(cmake)
else
  UV="$(command -v uv || true)"
  for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    if [ -z "$UV" ] && [ -x "$candidate" ]; then UV="$candidate"; fi
  done
  if [ -z "$UV" ]; then echo '构建语音组件需要 cmake 或 uv。' >&2; exit 1; fi
  CMAKE=("$UV" tool run --from cmake==3.31.6 cmake)
fi
"${CMAKE[@]}" -S Resources/Speech -B .build/speech-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DWHISPER_SOURCE="$SOURCE/whisper.cpp-1.9.3"
"${CMAKE[@]}" --build .build/speech-build --target FastOCRSpeech -j 4
