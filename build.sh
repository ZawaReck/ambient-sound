#!/bin/zsh
# AmbientSound.app を build/ 以下に作る（ad-hoc 署名）。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AmbientSound.app
mkdir -p "$APP/Contents/MacOS"
cp -f "$(swift build -c release --show-bin-path)/AmbientSound" "$APP/Contents/MacOS/AmbientSound"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "OK: $APP"
