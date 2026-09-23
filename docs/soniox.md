# Cloud speech recognition

VoiceCodex uses Soniox's real-time WebSocket API through Apple's `URLSessionWebSocketTask`. The first text frame configures `stt-rt-v5`, Chinese and English language hints, and raw 16 kHz, mono, signed 16-bit little-endian PCM. Microphone buffers are mixed down and resampled in memory, then sent as ordered binary frames.

Chinese (`zh`) and English (`en`) hints are enabled together, without strict language restriction or translation. Mixed Chinese/English speech is supported by the provider. Hints bias recognition; they do not force every recording into one language.

Each recording refreshes a vocabulary from installed GUI app names and known bundle-specific aliases. For example, an installed Chrome contributes “Google Chrome”, “Chrome”, and “谷歌浏览器”; Notes contributes “Notes”, “Apple Notes”, and “备忘录”. The current app and running apps are prioritized, followed by other installed apps. Safari and Finder are also resolved through Launch Services because normal directory traversal may omit them. The original six coding terms remain available in both modes.

The app sends this vocabulary using Soniox's structured `context.general` and `context.terms` fields. A shared alias table keeps speech recognition and Jev app selection consistent. Terms are deduplicated, sanitized, and bounded to 80 characters each; the entire serialized context stays within a conservative 7,000 UTF-8 bytes. If an unusually large inventory cannot fit, current/running apps keep priority and the UI tooltip reports omitted apps. The UI shows Chinese/English support and the loaded term count.

Vocabulary discovery runs after microphone capture starts, so its initial bundle scan cannot discard the opening word. It reads app bundle metadata, not window titles, documents, browsing history, or clipboard data. Only app display names and aliases are added to Soniox context; bundle IDs and private paths are not speech terms. App inventories and generated test audio/reports are not committed.

Recording starts while the connection opens. A bounded queue retains the initial audio; overflow fails the recording instead of dropping words. Releasing the shortcut stops the microphone, drains this queue, and sends an empty text frame. VoiceCodex accepts a transcript only after the provider sends `finished: true`. Network errors and timeouts never submit a provisional transcript to Codex.

Final tokens are appended once. Each response replaces the provisional tail. Endpoint markers are removed from the displayed and submitted text.

Your key belongs in `~/Library/Application Support/VoiceCodex/config.json`, with permissions `0600`, or the supported environment configuration. It is sent only to the Soniox WebSocket endpoint. Keys, recordings, and transcripts are not included in the repository or application bundle. Audio is sent to Soniox while you hold the shortcut; recordings are not written to disk by the app.

The native audio and push-to-talk design draws on experience from ReadyCall and Mens. This small client is written for this demo and uses the public provider protocol.

References:

- [Soniox WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api)
- [Soniox streaming tokens and audio formats](https://soniox.com/docs/stt/rt/real-time-transcription)
- [Soniox manual finalization](https://soniox.com/docs/stt/rt/manual-finalization)
- [Soniox supported languages](https://soniox.com/docs/stt/concepts/supported-languages)
- [Soniox language hints](https://soniox.com/docs/stt/concepts/language-hints)
- [Soniox context and vocabulary limits](https://soniox.com/docs/stt/concepts/context)
