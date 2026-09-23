# VoiceCodex

**Hold a key. Say what you need. Control your Mac.**

A native macOS voice controller with two modes: **Jev** selects native Mac actions, and **Codex** continues your coding session in Terminal. Soniox provides live Chinese / English transcription. In Mac mode, hold the shortcut from another app and pause between instructions: confirmed sentences start executing while the microphone remains open. Coding mode submits on release.

Chinese and English can be mixed in one command. Every recording automatically loads installed App names and common Chinese/English aliases as Soniox vocabulary, prioritizing the current and running apps. The transcription panel shows the loaded hotword count; no manual language switch is needed.

![VoiceCodex](docs/screenshot.jpg)

## Control your Mac with Jev

Inspired by [this Jev voice-control demo](https://www.youtube.com/shorts/vSzde5be5XE). The app uses TypeSafe's Jev API directly from Swift; no Node service, generated scripts, or Codex login is needed in Mac mode.

1. Build and open the app with `./script/build_and_run.sh --install`.
2. Choose **控制 Mac · Jev** and click **打开 .env**. Fill `TYPESAFE_API_KEY` with your TypeSafe key. The default model is pinned to `jev-1.13.0`. Save the file; the next command reloads it.
3. Set a Soniox key in Settings, or set `SONIOX_API_KEY` in `.env`. An existing saved Soniox key is reused when the `.env` value is blank.
4. Click **启用辅助功能** and enable VoiceCodex in macOS System Settings. Microphone access is requested on first recording.
5. Leave **边说边做** enabled, hold **Control + Option + Space**, and speak. Pause after a sentence to begin execution before releasing the key. Release ends listening and flushes only the remaining confirmed text. **Esc** stops listening and clears later actions. Turn the checkbox off to execute after release. The text field supports the same sequences.

Try these commands:

| Say | Action |
| --- | --- |
| “打开 Chrome” / “Open Calculator” | Open or activate an installed app |
| “在 Chrome 新建一个标签页” | Send ⌘T to Chrome |
| “关闭当前标签页” | Close only the current browser tab with ⌘W |
| “打开 Chrome，然后新建一个标签页” | Open Chrome, then act in that same app |
| “打开腾讯会议，然后创建一个新的会议” | Open Tencent Meeting, then select its observed new/quick-meeting control for review |
| “输入「hello world」” / “Type hello world” | Insert your literal text at the focused editor's selection |
| “向下滚动” / “复制” / “撤销” | Operate the captured target app |
| “点击保存按钮” | Choose from observed, enabled Accessibility controls |
| “关闭 Chrome 的所有窗口” | Review, then close observed windows; stop at a save dialog |

Jev chooses from a fixed action vocabulary and observed app/control IDs. It does not generate prose, scripts, shell commands, or text to type. Literal typing content is held locally and hidden from action selection, so saying “输入「打开 Chrome」” enters those words. Connect up to six explicit actions with “然后”, “接着”, “再”, “then”, or “and then”. Quoted content is never split: `输入「先打开，再关闭」然后按回车` types the exact quoted text, then reviews Return. Open-ended research/writing workflows are not implemented in Mac mode. Typing preserves the rest of an editable field and does not press Return. Protected fields and terminal input are blocked. When an app exposes no usable Accessibility buttons, optional **屏幕识别** reads only its target window using Apple Vision locally. Jev receives bounded recognized labels, never the screenshot. You review the exact target before a click; the app rechecks the window, label, and position afterward. This needs macOS Screen Recording permission in addition to Accessibility. Unlabeled icons and ambiguous or changing text still require a manual click.

The initial unnamed target is captured when recording starts. Each successful action carries its app target to the next step, including later sentences in the same recording. Planning and fresh observation happen one step at a time. Up to 12 pending steps can queue; a failed, rejected, or cancelled step discards the rest and ends live listening. Return, paste, clicking a control, and closing all windows have an in-app review step; clicking shows the selected label. A cancellation stops later actions; it does not undo input already delivered. Receipts distinguish observed changes from shortcuts whose final effect cannot be verified.

“关闭窗口” closes the whole window, including its tabs. Use “关闭当前标签页” for one tab. New-tab and new-window commands can launch a stopped target app. Confirmation binds to the selected process, window, and input field; changing them while reviewing stops the action.

### Local `.env`

The installed app defaults to `~/Library/Application Support/VoiceCodex/.env`. Use **打开 .env** to create/open it with private file permissions. For a development launch, `.env` in the working directory or `VOICECODEX_ENV_FILE` can override it. `.env.example` is a template only; no key is bundled.

```dotenv
TYPESAFE_API_KEY=
TYPESAFE_DEFAULT_MODEL=jev-1.13.0
SONIOX_API_KEY=
```

Precedence is saved settings → Application Support `.env` → selected development `.env` → process environment. Blank key values preserve an existing key. Parsing is literal: no shell execution or variable expansion. Never commit real `.env` files. See [Jev integration details](docs/jev.md).

## Codex coding mode

- Global **Control + Option + Space** push-to-talk (Control + Shift + Space fallback if occupied).
- Live Chinese / English transcription with Soniox's streaming WebSocket API.
- A floating recording indicator, live transcript, and microphone level.
- Automatic submission on release; **Esc** cancels the current recording.
- One independent Git worktree per new task, based on the selected checkout's committed HEAD.
- Explicit Codex session IDs for follow-up instructions; new instructions queue while Codex runs.
- A visible, interactive Codex session in **Terminal.app**, text-input fallback, and a stop button.

This is an early demo. Release the shortcut to send your instruction to a real Codex TUI in Terminal. Its output, tool calls, approval prompts, and replies appear there. You can also type directly in that terminal. Closing the VoiceCodex window leaves the menu-bar app running. Open VoiceCodex again from Finder or Spotlight to restore that same window; the menu-bar menu also has an Open VoiceCodex action.

## Run

Requires macOS 14+, Xcode Command Line Tools / Swift 5.9+, and a [Soniox API key](https://console.soniox.com/) for speech. Mac mode also needs a TypeSafe API key; coding mode needs an installed, authenticated [Codex CLI](https://developers.openai.com/codex/cli/).

```sh
git clone https://github.com/Singularity-tian/voicecodex.git
cd voicecodex
# Select and remember your signing identity using the command below.
```

Terminal mode requires a CLI with `--remote` and the app-server queue API; tested with **Codex CLI 0.153.2**.

The script builds and signs a local app bundle, installs it at `~/Applications/VoiceCodex.app`, and launches it. This is the current user's Applications folder. The app is a source-built demo, not a notarized distribution.

For stable permissions across updates, choose an exact certificate name or full fingerprint from `security find-identity -v -p codesigning`, then install once with:

```sh
VOICECODEX_SIGNING_IDENTITY="YOUR CODE-SIGNING CERTIFICATE FINGERPRINT" \
  ./script/build_and_run.sh --install --remember-signing-identity
```

Only after the installed signature verifies does the script save the fingerprint in `~/Library/Application Support/VoiceCodex/signing-identity` (mode `0600`). Later builds reuse it; `VOICECODEX_SIGNING_IDENTITY` takes precedence. An unavailable saved identity stops the build instead of falling back to ad hoc signing. Switching signing identities may require one new permission grant. Continue using `--install` to update and launch the same app location.

Without a configured identity, `--build-only` supports ad hoc CI builds. An intentional temporary run/install can use `VOICECODEX_SIGNING_IDENTITY=-`; ad hoc identities cannot be remembered and changing those builds can require renewed permissions. The saved identity is literal local data, never shell code, and does not contain a private key.

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

新任务从项目已提交的 HEAD 创建独立 worktree。原目录中未提交的改动不会自动复制。继续说话会沿用同一个会话；Codex 正忙时，新指令进入队列。关闭 Terminal 后，再次说话会恢复原会话；选择新任务会结束旧的终端连接，保留工作目录。关闭 VoiceCodex 窗口仍可用全局快捷键；再次从 Finder 或 Spotlight 打开 VoiceCodex，会恢复原窗口和会话。菜单栏也有「打开 VoiceCodex」入口。从菜单栏退出应用会停止它管理的 Codex 服务。

## Local data and permissions

- Audio is captured only for an explicit recording and streamed to **Soniox**. VoiceCodex keeps audio in memory and does not save recordings.
- Each recording also sends **Soniox** a bounded vocabulary of installed App display names and known aliases. It contains no app paths, window titles, documents, or history; see [speech configuration](docs/soniox.md).
- Mac live mode executes only finalized Soniox utterances (`<end>`), never provisional words. It submits the final confirmed remainder once at a successful EOF. A later network/transcription error stops pending actions; actions already delivered remain. With live mode off, and in Codex mode, submission waits for final completion.
- Final text is sent to **Codex**, using the account and provider configuration already configured for your CLI.
- In Mac mode, the routing instruction and app names/identifiers are sent to **TypeSafe**. Recognized literal typing payloads are replaced with a placeholder and remain local during planning. A click command additionally sends bounded Accessibility role/title/description text for the selected window. Optional visual fallback sends only bounded OCR labels from the target window; screenshots are processed locally in memory, never saved or uploaded. Clipboard contents and whole documents are not sent to Jev. Transcripts and action receipts are saved privately in `mac-history.txt`, separately from the coding session history.
- Settings, the Soniox credential, session IDs, and local transcript/output history live in `~/Library/Application Support/VoiceCodex/`. Config and history files use mode `0600`.
- Task worktrees live under that directory's `worktrees/`. They are preserved when you start a new task; remove finished ones with `git worktree remove` when ready.
- The Soniox key is used by the voice app and is not added to the Codex child-process environment. `SONIOX_API_KEY` is also supported for explicitly configured development launches.
- The TypeSafe key is likewise removed from managed Codex child-process environments. Neither key appears in command arguments.
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

For opt-in real API checks and disposable desktop scenarios, see [the QA guide](docs/testing.md). Synthetic speech checks exercise Soniox finalization and Jev planning without recording the microphone or operating other apps.

| Component | Responsibility |
| --- | --- |
| `GlobalHotkey` | Carbon global press/release events |
| `RealtimeSTT` | AVAudioEngine capture, PCM conversion, Soniox streaming and finalization |
| `JevClient` | Typed action/app/control selection, confidence and response validation |
| `MacControlDriver` | Native app activation, targeted input, bounded AX reads and receipts |
| `MacCommandSequence` / `MacSequenceExecutor` | Quote-aware ordered steps, serial queue, target carry and stop-on-failure |
| `VisualControlObserver` | Optional local target-window OCR and fresh candidate matching |
| `EnvironmentFile` | Literal `.env` parsing without shell execution |
| `AppController` | Recording lifecycle, prompt queue, session selection and local state |
| `TerminalSession` | Authenticated local app-server, literal JSON prompts, queue, status and interruption |
| `TerminalLauncher` | Private launch files for a real Codex TUI in Terminal.app |
| `CodexRunner` | Original non-interactive runner, retained as a tested core utility |
| `WorkspaceManager` | Git worktree creation without modifying the source checkout |

Voice and typed prompts are sent as literal JSON over the authenticated local WebSocket, never interpolated into shell source. Terminal is opened using macOS application APIs; no simulated typing or AppleScript Automation permission is required. The STT adapter uses a documented public protocol; see [the Soniox integration notes](docs/soniox.md).

## License

MIT. Independent community project; not affiliated with OpenAI or Soniox.
