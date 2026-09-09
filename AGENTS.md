# VoiceCodex

Native macOS push-to-talk launcher for Codex CLI. Build with SwiftPM and launch the app bundle with `./script/build_and_run.sh`.

- Never commit API keys, local configuration, recordings, transcripts, or private project paths. Credentials belong in the user's local application support directory or environment.
- Keep speech-provider code independent of the Codex process runner.
- Feed prompts through stdin, never shell interpolation.
- Keep recording, connecting, finishing, executing, and failure states visible.
- Run `swift test` and build the app before publishing changes.
- Git worktrees isolate coding tasks. Preserve existing user files and session IDs.
