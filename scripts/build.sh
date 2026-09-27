#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-speech.sh
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/FastOCR.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FastOCR" "$APP/Contents/MacOS/FastOCR"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Offline"
cp Resources/Offline/*.py Resources/Offline/*.sh "$APP/Contents/Resources/Offline/"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Speech"
cp .build/speech-build/FastOCRSpeech "$APP/Contents/Helpers/"
cp Resources/Speech/setup.sh "$APP/Contents/Resources/Speech/"
cp .build/speech-source/whisper.cpp-1.9.3/LICENSE "$APP/Contents/Resources/Speech/whisper-LICENSE"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP/Contents/Helpers/FastOCRSpeech"
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP"
fi
printf 'Built: %s\n' "$APP"
