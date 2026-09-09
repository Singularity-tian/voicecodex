# VoiceCodex

**Hold a key. Say what you need. Let Codex work.**

A small native macOS app that streams your voice to Soniox and sends the final transcript directly to Codex CLI. It works while another app is in front. Release the shortcut to execute; keep talking to continue the same Codex session.

![VoiceCodex](docs/screenshot.png)

## What it does

- Global **Control + Option + Space** push-to-talk (Control + Shift + Space fallback if occupied).
- Live Chinese / English transcription with Soniox's streaming WebSocket API.
- A floating recording indicator, live transcript, and microphone level.
- Automatic submission on release; **Esc** cancels the current recording.
- One independent Git worktree per new task, based on the selected checkout's committed HEAD.
- Explicit Codex session IDs for follow-up instructions; new instructions queue while Codex runs.
- A visible, interactive Codex session in **Terminal.app**, text-input fallback, and a stop button.

This is an early demo. Release the shortcut to send your instruction to a real Codex TUI in Terminal. Its output, tool calls, approval prompts, and replies appear there. You can also type directly in that terminal. Closing the VoiceCodex window leaves the menu-bar app running.

## Run

Requires macOS 14+, Xcode Command Line Tools / Swift 5.9+, a [Soniox API key](https://console.soniox.com/), and an installed, authenticated [Codex CLI](https://developers.openai.com/codex/cli/).

```sh
git clone https://github.com/Singularity-tian/voicecodex.git
cd voicecodex
./script/build_and_run.sh --install
```

Terminal mode requires a CLI with `--remote` and the app-server queue API; tested with **Codex CLI 0.153.2**.

The script builds a local app bundle, signs it ad hoc, installs it at `~/Applications/VoiceCodex.app`, and launches it. It is a source-built demo, not a notarized distribution.

Developers with a signing certificate can set `VOICECODEX_SIGNING_IDENTITY` to their own identity when building. A stable signing identity avoids repeated permission resets as the app changes.

1. Open **设置**, enter your Soniox key and check the Codex executable path. VoiceCodex reuses your existing `codex login` authentication.
2. Click **选择项目** and pick a Git repository with at least one commit.
3. Hold **⌃⌥Space**, allow the microphone on first use, then hold again and speak.
4. Release to open **Terminal** and run. Complete any first-run Codex prompts in the terminal. Subsequent voice instructions go to that same session. Choose **新任务** to start fresh.
5. Use **打开终端** to return to Terminal. Full output and any approval questions stay there; the app shows your submitted instructions and connection state.

macOS may also request access to the folder containing your selected project. Allow that request to let Git read the repository; if a task times out while waiting for permission, allow access and retry.

You can also hold the **按住说话** button, or type a prompt in the bottom field and press Return.

### 中文快速开始

打开设置填入 Soniox API key，选择一个 Git 项目。按住 **Control + Option + Space** 说话，松手后自动交给 Codex；**Esc** 取消录音。第一次需要允许麦克风，授权后再次按住开始。

松手后自动打开 macOS **Terminal**，运行真正的交互式 Codex。完整执行过程、工具输出、确认提示和回复都在终端显示，也可以直接键入。点 **打开终端** 随时切回。

新任务从项目已提交的 HEAD 创建独立 worktree。原目录中未提交的改动不会自动复制。继续说话会沿用同一个会话；Codex 正忙时，新指令进入队列。关闭 Terminal 后，再次说话会恢复原会话；选择新任务会结束旧的终端连接，保留工作目录。关闭 VoiceCodex 窗口仍可用全局快捷键；从菜单栏退出应用会停止它管理的 Codex 服务。

## Local data and permissions

- Audio is captured only for an explicit recording and streamed to **Soniox**. VoiceCodex keeps audio in memory and does not save recordings.
- The app waits for Soniox's final completion response. A network or transcription error does not execute a partial transcript.
- Final text is sent to **Codex**, using the account and provider configuration already configured for your CLI.
- Settings, the Soniox credential, session IDs, and local transcript/output history live in `~/Library/Application Support/VoiceCodex/`. Config and history files use mode `0600`.
- Task worktrees live under that directory's `worktrees/`. They are preserved when you start a new task; remove finished ones with `git worktree remove` when ready.
- The Soniox key is used by the voice app and is not added to the Codex child-process environment. `SONIOX_API_KEY` is also supported for explicitly configured development launches.
- The interactive TUI runs with `-a on-request`, `--sandbox workspace-write`, and `--no-alt-screen` to keep terminal scrollback. Approval prompts appear in Terminal. Tool-specific and macOS permissions still apply; Terminal mode does not grant access to a blocked app.
- Each active VoiceCodex connection uses its own Codex app-server bound to `127.0.0.1`, protected by a random bearer token in a private local file. It does not replace or restart any existing Codex daemon. The Terminal launcher reads that token into a named environment variable; it is not embedded in the launch script or command arguments.
- Stop clears pending instructions and requests interruption of the active turn; the terminal remains available for another instruction. Closing its Terminal session, starting a new task, or quitting VoiceCodex shuts down the server owned by the app. Already-completed edits remain; detached child processes are not independently managed by this demo.

Do not put real API keys in the repository or bundle. Other users must supply their own credential; no shared public key is included.

## Development

```sh
swift test
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
```

The Codex app's Run action calls `script/build_and_run.sh`. Other modes include `--logs`, `--telemetry`, and `--debug`.

| Component | Responsibility |
| --- | --- |
| `GlobalHotkey` | Carbon global press/release events |
| `RealtimeSTT` | AVAudioEngine capture, PCM conversion, Soniox streaming and finalization |
| `AppController` | Recording lifecycle, prompt queue, session selection and local state |
| `TerminalSession` | Authenticated local app-server, literal JSON prompts, queue, status and interruption |
| `TerminalLauncher` | Private launch files for a real Codex TUI in Terminal.app |
| `CodexRunner` | Original non-interactive runner, retained as a tested core utility |
| `WorkspaceManager` | Git worktree creation without modifying the source checkout |

Voice and typed prompts are sent as literal JSON over the authenticated local WebSocket, never interpolated into shell source. Terminal is opened using macOS application APIs; no simulated typing or AppleScript Automation permission is required. The STT adapter uses a documented public protocol; see [the Soniox integration notes](docs/soniox.md).

## License

MIT. Independent community project; not affiliated with OpenAI or Soniox.
