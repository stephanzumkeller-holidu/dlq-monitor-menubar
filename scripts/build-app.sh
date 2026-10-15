#!/bin/zsh
# Builds "DLQ Monitor.app" into ./build, ad-hoc signed for local use.
# Needs only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/DLQ Monitor.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DLQMonitor" "$APP/Contents/MacOS/DLQMonitor"
sed -e "s/__VERSION__/${VERSION#v}/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP ($VERSION)"
