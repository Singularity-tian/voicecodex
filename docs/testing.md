# Testing VoiceCodex

Keep unit, live API, microphone, and desktop evidence separate. A valid plan proves intent selection; a shortcut receipt proves delivery only. Verify the destination app before marking a desktop scenario passed.

## Repeatable checks

```sh
swift test
./script/build_and_run.sh --verify --install
```

The following checks use local credentials and make paid requests only with `--live`. They never operate desktop apps. Generated audio and reports stay under ignored `.build/qa`; do not commit recordings, returned transcripts, credentials, or local configuration.

```sh
swiftc Sources/VoiceCodexCore/EnvironmentFile.swift \
  Sources/VoiceCodexCore/MacCommand.swift Sources/VoiceCodexCore/SpeechVocabulary.swift \
  Sources/VoiceCodexCore/JevClient.swift \
  script/jev_live_check.swift -o .build/jev-live-check
.build/jev-live-check --live
.build/jev-live-check --live --installed-apps --output .build/qa/jev-live-installed-apps.json
./script/test_speech_live.sh --live
./script/test_speech_live.sh --live --vocabulary-ab
```

The planner matrix checks Chinese/English app names, current/named targets, tabs versus windows, exact text including emoji and line breaks, quoted command words, scroll/copy/paste/undo/Return/click intents, and rejection of missing targets, unavailable apps, ambiguous typing destinations, unsupported operations, and multi-step requests. Every successful case checks the exact action, app, and literal text. A safe rejection is expected only for the explicitly negative cases. The installed-app option uses real bundle metadata and a focused subset; it does not read windows or operate apps.

The speech script synthesizes five fixed English/Mandarin phrases to files with built-in macOS voices, uses the production PCM encoder and Soniox streaming/finalization code, and passes the confirmed transcript to the real Jev client. Three cases open apps; two insert literal text into a captured TextEdit target. Speech has no intrinsic letter case or punctuation: the typing oracle accepts an explicit small set of transcript formatting variants, independently of the production parser. It does not play audio, capture the microphone, or test the global hotkey.

The vocabulary A/B option uses the real installed-app catalog and up to ten fixed public app-name phrases; fixtures for absent apps are skipped. It compares the original six terms with the production app vocabulary, keeping the general context identical. Each pair reuses the same PCM bytes, records their SHA-256, and alternates arm order. It checks final transcript completion, app-name recognition, and the exact Jev action and target separately. Inventory names are sent as the requested recognition context but are not saved in the report. Use `--filter FIXTURE_ID` for a targeted recheck. Clean synthetic speech can verify the pipeline; it cannot establish accuracy for a person's accent or microphone.

## Disposable desktop target

```sh
./script/build_qa_target.sh
```

Open the printed app bundle in Finder. It contains empty input fields, a counter, a scrollable editor, and disposable windows; it reads/writes no documents and makes no network requests. It appears in VoiceCodex's app inventory while running. Use its full name, **VoiceCodex QA Target**, when specifying a target.

After granting Accessibility to the installed VoiceCodex build, run these scenarios one at a time through its text field, then repeat representative cases by holding the voice shortcut from the target app. Observe both the action receipt and the actual destination.

| Scenario | Expected destination state |
| --- | --- |
| Open Calculator and Chrome in Chinese/English | Correct app becomes visible |
| Create a Chrome tab, then close that tab | Exactly the new test tab closes; existing tabs remain |
| Create a QA window from another foreground app | One additional disposable window |
| Insert quoted Chinese, emoji, and multiple lines | Exact text; surrounding content preserved; no Return |
| Replace selected text in the QA editor | Only that selection changes |
| Type quoted text containing “open Chrome” or “close all windows” | Only literal text is inserted; no app opens or closes |
| Copy selected QA text, confirm paste into another QA field | Matching text appears in the selected field |
| Undo a native edit | Previous editor state restored |
| Confirm Return in the multiline editor | A line break appears |
| Click “Increment counter” and confirm | Counter increments exactly once |
| Scroll a long QA document down/up | Editor scroll position visibly changes |
| Close one QA window | Other QA windows remain |
| Confirm closing all QA windows | All observed disposable windows close |
| Cancel the in-app review | Target remains unchanged |
| Change target window/field during review | Action stops with a changed-target message |
| Missing Accessibility permission | Action stops and offers the permission settings |
| Stop during an in-flight request | No later action executes; app accepts the next command |

Use disposable windows for close-all testing. Do not close existing user documents or browser windows. A save dialog should halt closing, never be answered automatically. Protected fields and terminal input should be rejected before sending text.

## Recorded validation — 2026-09-23

- 95 unit tests passed; debug app built, signed, installed, and its process verified. One earlier full run hit an existing Git-timeout fixture startup failure before its PID marker was written; the isolated recheck and complete rerun passed. The failure log is retained locally; no production timeout was changed.
- Real Jev planner matrix: 41/41 passed. A real inventory of 131 installed apps passed nine selected cases and all four literal-command confusion cases. The final destination ambiguity guard passed four targeted cases, including local rejection before HTTP. Fixes retained the 0.75 confidence cutoff.
- The earlier 27/33 baseline exposed Chinese app-name, named-app typing, and multiline defects. Four later literal-command probes initially failed 0/4; structural payload isolation fixed all four. Earlier failing reports are retained locally.
- Synthetic audio → production PCM encoding → real Soniox final completion → real Jev planning: 5/5 passed. The first typing run was 4/5 because its lowercase-only expectation excluded ASR title casing; the revised oracle explicitly allows that observed case variation, and the earlier report is retained.
- The final installed app opened Calculator, Stickies, Chrome, and the disposable QA app. It correctly classified a quoted command as literal input and stopped at the missing Accessibility permission; a multi-step typing request was rejected without execution. Expanded native input/tab/click/confirmation tests remain pending user-granted Accessibility. Microphone hardware and global push-to-talk have not been independently exercised by the test harness.

These are bounded regression results, not a claim that every phrasing or application works. Live model decisions can vary; preserve failures and retest the changed behavior rather than lowering the confidence threshold to hide a failure.

## Application vocabulary validation — 2026-09-23

- 106 unit tests passed, including encoded Soniox language/context configuration, bilingual app aliases, deduplication, sanitization, current-app priority, and the complete-context size bound.
- Final app built, signed, installed, and its running process verified. The installed UI visibly showed `SONIOX · 中文 / English · 166 热词`; the screenshot is retained locally under ignored `.build/qa`.
- The production catalog represented all 132 installed applications with 166 terms in 2,204 UTF-8 bytes, with no applications omitted. Safari and Finder were included through verified Launch Services bundle resolution.
- Eight public app-name clips tested Chrome in English/mixed speech, Apple Notes and Stickies in English/Chinese, and Feishu and WeChat in Chinese. Both arms passed 8/8 for finalized transcripts, recognized app names, and correct Jev targets: 16/16 live Soniox-to-Jev evaluations. The original six-term arm used the same general context as the application arm. VS Code fixtures were skipped because the app was not installed.
- Seven pairs ran together; the Feishu fixture's bundle ID was then corrected to match the installed app and its pair ran separately. Each pair used identical PCM bytes. Original reports and the combined summary remain in ignored `.build/qa`.
- Both arms already succeeded on these clean clips. No measurable accuracy improvement was demonstrated, and microphone capture, personal pronunciation, and desktop action execution were not tested by this A/B harness.

## Merge review validation — 2026-09-23

- Full independent review covered native execution and target binding, Jev routing and response validation, speech lifecycle, credential isolation, scripts, and Codex session compatibility. Four findings were fixed before merge: control-label words mistaken for typing, bare 回车/换行 compound requests hidden as literal text, ordinary document titles mistaken for terminals, and queued cancellation not running before synchronous native input.
- `swift test`: 113 tests passed. The new controlled main-actor scheduling fixture queues cancellation during a simulated blocking read and verifies zero writes; an uncancelled action executes once. Terminal app/widget guards remain, while document/window metadata no longer determines terminal identity. This is cooperative cancellation at checkpoints, not preemption of an in-flight AX call.
- Real Jev review cases: 8/8 passed, covering named controls in English/Chinese (with and without descriptive words), compound-request rejection before HTTP, and exact quoted payloads. The first run passed 5/6: “Click the Enter button” was safely rejected with confidence 0.67. Clarifying click intent versus keyboard Return fixed that case without changing the 0.75 threshold. The first report remains local. Reproduce with `.build/jev-live-check --live --filter review-` after compiling as above.
- A separate live recheck of Chinese Return, “Press Enter”, and “Hit Return” passed 3/3 after the intent clarification.
- Final app rebuilt, signed, installed, and process-verified. Through its actual text-command UI, the bare “输入 hello 然后回车” request was rejected; “打开计算器” produced a successful app-open receipt and the Calculator window was observed separately.
- Native text insertion, tab manipulation, control clicks, microphone hardware, and global push-to-talk still require desktop acceptance with user-granted permissions; the new fixture and live planner checks do not prove those outcomes.
