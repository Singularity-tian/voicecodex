# Cloud speech recognition

VoiceCodex uses Soniox's real-time WebSocket API through Apple's `URLSessionWebSocketTask`. The first text frame configures `stt-rt-v5`, Chinese and English language hints, and raw 16 kHz, mono, signed 16-bit little-endian PCM. Microphone buffers are mixed down and resampled in memory, then sent as ordered binary frames.

Recording starts while the connection opens. A bounded queue retains the initial audio; overflow fails the recording instead of dropping words. Releasing the shortcut stops the microphone, drains this queue, and sends an empty text frame. VoiceCodex accepts a transcript only after the provider sends `finished: true`. Network errors and timeouts never submit a provisional transcript to Codex.

Final tokens are appended once. Each response replaces the provisional tail. Endpoint markers are removed from the displayed and submitted text.

Your key belongs in `~/Library/Application Support/VoiceCodex/config.json`, with permissions `0600`, or the supported environment configuration. It is sent only to the Soniox WebSocket endpoint. Keys, recordings, and transcripts are not included in the repository or application bundle. Audio is sent to Soniox while you hold the shortcut; recordings are not written to disk by the app.

The native audio and push-to-talk design draws on experience from ReadyCall and Mens. This small client is written for this demo and uses the public provider protocol.

References:

- [Soniox WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api)
- [Soniox streaming tokens and audio formats](https://soniox.com/docs/stt/rt/real-time-transcription)
- [Soniox manual finalization](https://soniox.com/docs/stt/rt/manual-finalization)
