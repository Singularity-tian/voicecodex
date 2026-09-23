#!/usr/bin/env bash
set -euo pipefail
umask 077

SPEECH_QA_OPTIONS=()
SPEECH_QA_AB=false
SPEECH_QA_LIVE=false
SPEECH_QA_ENDPOINTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) SPEECH_QA_LIVE=true; SPEECH_QA_OPTIONS+=(--live); shift ;;
    --vocabulary-ab) SPEECH_QA_AB=true; SPEECH_QA_OPTIONS+=(--vocabulary-ab); shift ;;
    --endpoints) SPEECH_QA_ENDPOINTS=true; SPEECH_QA_OPTIONS+=(--endpoints); shift ;;
    --filter)
      [[ $# -ge 2 ]] || { echo "--filter requires one fixture ID" >&2; exit 2; }
      SPEECH_QA_OPTIONS+=(--filter "$2"); shift 2 ;;
    *) echo "Unknown option" >&2; exit 2 ;;
  esac
done
if ! $SPEECH_QA_LIVE; then
  echo "Usage: $0 --live [--vocabulary-ab] [--filter FIXTURE_ID] | --live --endpoints"
  echo "Default: sends five fixed synthetic speech clips to Soniox, then transcripts to TypeSafe."
  echo "A/B: at most ten public app-name clips × two term sets, using the same audio for each pair."
  echo "Endpoints: two clips in one Soniox stream; checks delivery before EOF and no duplicates, without TypeSafe."
  echo "Uses local credentials; never records the microphone or operates desktop apps."
  exit 2
fi

SPEECH_QA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SPEECH_QA_ROOT"
mkdir -p .build/qa/speech-live-audio .build/qa/speech-core

# File output only: these commands never play speech through the speakers.
# A/B fixtures are generated once; both arms receive those exact converted bytes.
if $SPEECH_QA_ENDPOINTS; then
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-chrome.aiff 'Open Google Chrome'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-calculator.aiff 'Open Calculator'
elif $SPEECH_QA_AB; then
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/vocab-chrome-en.aiff 'Open Google Chrome'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-chrome-mixed.aiff '打开 Chrome'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/vocab-notes-en.aiff 'Open Apple Notes'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-notes-zh.aiff '打开备忘录'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/vocab-stickies-en.aiff 'Open Stickies'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-stickies-zh.aiff '打开便笺'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/vocab-vscode-en.aiff 'Open Visual Studio Code'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-vscode-mixed.aiff '打开 Visual Studio Code'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-feishu-zh.aiff '打开飞书'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/vocab-wechat-zh.aiff '打开微信'
else
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-calculator.aiff 'Open Calculator'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-chrome.aiff 'Open Google Chrome'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/zh-calculator.aiff '打开计算器'
  /usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-type.aiff 'Type hello world'
  /usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/zh-type.aiff '输入你好世界'
fi

# Compile production code directly without taking the SwiftPM build lock.
# The driver is used only for the same read-only app discovery as the real app.
xcrun swiftc -parse-as-library -module-name VoiceCodexCore -emit-module -emit-library \
  Sources/VoiceCodexCore/*.swift \
  -emit-module-path .build/qa/speech-core/VoiceCodexCore.swiftmodule \
  -Xlinker -install_name -Xlinker '@rpath/libVoiceCodexCore.dylib' \
  -o .build/qa/speech-core/libVoiceCodexCore.dylib
xcrun swiftc -parse-as-library \
  -I .build/qa/speech-core -L .build/qa/speech-core -lVoiceCodexCore \
  -Xlinker -rpath -Xlinker '@executable_path/speech-core' \
  Sources/VoiceCodex/RealtimeSTT.swift \
  Sources/VoiceCodex/VisualControlObserver.swift \
  Sources/VoiceCodex/MacControlDriver.swift \
  script/speech_live_check.swift \
  -o .build/qa/speech-live-check

exec .build/qa/speech-live-check "${SPEECH_QA_OPTIONS[@]}"
