#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "${1:-}" != "--live" || $# != 1 ]]; then
  echo "Usage: $0 --live"
  echo "Sends five fixed synthetic speech clips to Soniox, then their transcripts to TypeSafe."
  echo "Uses local credentials; never records the microphone or operates desktop apps."
  exit 2
fi

SPEECH_QA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SPEECH_QA_ROOT"
mkdir -p .build/qa/speech-live-audio

# File output only: these commands never play speech through the speakers.
# Built-in voices are named explicitly so both English and Mandarin are tested.
/usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-calculator.aiff 'Open Calculator'
/usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-chrome.aiff 'Open Google Chrome'
/usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/zh-calculator.aiff '打开计算器'
/usr/bin/say -v Samantha -r 150 -o .build/qa/speech-live-audio/en-type.aiff 'Type hello world'
/usr/bin/say -v Tingting -r 150 -o .build/qa/speech-live-audio/zh-type.aiff '输入你好世界'

# Compile production sources directly, without taking the SwiftPM build lock.
xcrun swiftc -parse-as-library \
  Sources/VoiceCodexCore/EnvironmentFile.swift \
  Sources/VoiceCodexCore/MacCommand.swift \
  Sources/VoiceCodexCore/JevClient.swift \
  Sources/VoiceCodex/RealtimeSTT.swift \
  script/speech_live_check.swift \
  -o .build/qa/speech-live-check

exec .build/qa/speech-live-check --live
