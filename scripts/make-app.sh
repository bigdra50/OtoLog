#!/usr/bin/env bash
# SwiftPM ビルドの実行ファイルを dist/OtoLog.app へ組み立てて署名する。
# CFBundleIdentifier は TCC（画面収録）の許可に紐づくため固定・不変にする。
set -euo pipefail

cd "$(dirname "$0")/.."

# リリース時は CI がタグ（v0.1.0 → 0.1.0）を OTOLOG_VERSION で渡す。ローカルは既定値。
VERSION="${OTOLOG_VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# ad-hoc 署名はビルドごとに CDHash が変わり TCC 許可が剥がれる。
# 日常利用では自己署名証明書を作り OTOLOG_CODESIGN_IDENTITY で指定する（README 参照）
IDENTITY="${OTOLOG_CODESIGN_IDENTITY:--}"

swift build -c release --product OtoLog

APP=dist/OtoLog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OtoLog "$APP/Contents/MacOS/OtoLog"
# SwiftPM 依存がリソース bundle を持つ場合に備えて同梱する（MarkdownUI 2.4.1 時点では無し）
cp -R .build/release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.bigdra50.OtoLog</string>
	<key>CFBundleName</key><string>OtoLog</string>
	<key>CFBundleDisplayName</key><string>OtoLog</string>
	<key>CFBundleExecutable</key><string>OtoLog</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSDocumentsFolderUsageDescription</key><string>文字起こし結果を日次ファイルとして保存するために使用します。</string>
	<key>NSAudioCaptureUsageDescription</key><string>システムで再生中の音声を文字起こしするために使用します。画面は取得しません。</string>
	<key>NSMicrophoneUsageDescription</key><string>マイクの音声（自分の発言）を文字起こしするために使用します。</string>
	<key>NSRemovableVolumesUsageDescription</key><string>外部ボリューム上の保存先に文字起こし結果を読み書きするために使用します。</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" "$APP"
echo "built: $APP (identity: ${IDENTITY}, version: ${VERSION} (${BUILD_NUMBER}))"
