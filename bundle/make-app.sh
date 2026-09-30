#!/usr/bin/env bash
# Assemble a distributable "Notch.app" from the SwiftPM build — no Xcode.
# Steps: release build -> bundle layout -> Info.plist -> lint -> ad-hoc sign -> zip.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Notch"
BUNDLE_ID="io.github.dedavil.notch"
OUT_DIR="build"
APP="${OUT_DIR}/${APP_NAME}.app"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"

echo "==> building release (arm64)"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/NotchApp"
[ -x "$BIN" ] || { echo "build product missing: $BIN"; exit 1; }

echo "==> assembling ${APP} (version ${VERSION})"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/NotchApp"

sed "s/__VERSION__/${VERSION}/g" bundle/Info.plist.template > "${APP}/Contents/Info.plist"
plutil -lint "${APP}/Contents/Info.plist"

echo "==> ad-hoc codesign"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo "==> zipping"
( cd "$OUT_DIR" && ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME// /-}.zip" )

echo "done: ${APP}"
echo "      ${OUT_DIR}/${APP_NAME// /-}.zip"
