#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_BUNDLE="$ROOT_DIR/.build/qa/VoiceCodex QA Target.app"
mkdir -p "$QA_BUNDLE/Contents/MacOS"
swiftc "$ROOT_DIR/Tests/Fixtures/MacControlTarget.swift" -o "$QA_BUNDLE/Contents/MacOS/VoiceCodexQATarget"
cat > "$QA_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceCodexQATarget</string>
<key>CFBundleIdentifier</key><string>com.singularity.voicecodex.qa-target</string>
<key>CFBundleName</key><string>VoiceCodex QA Target</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$QA_BUNDLE"
echo "$QA_BUNDLE"
