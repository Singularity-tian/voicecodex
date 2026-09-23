# Jev integration

VoiceCodex calls the official [TypeSafe evaluation endpoint](https://docs.typesafe.ai/api): `POST https://api.typesafe.ai/v1/systemone`, authenticated with a bearer key. Requests contain a `state`, pinned model, and named `choice` questions. Responses must select one of the submitted candidates with a valid probability distribution and confidence of at least 0.75. This threshold is a local policy, not an accuracy guarantee.

The action vocabulary is fixed in `MacIntent`. Application choices map opaque request IDs to locally discovered bundle identifiers. Large app inventories are routed in bounded groups to respect the API's 255-choice limit. For a control click, only enabled AX controls from a bounded observation of the selected window become candidates. The driver checks foreground app, window identity, control membership and label again before clicking.

Jev cannot generate insertion text. Quoted spans and explicit “输入 / type / write / says” suffixes are extracted locally, and Jev can select only those exact strings. The driver inserts into an editable AX field, preserves surrounding content, rejects secure fields and terminal input, and never interprets text as code. Use explicit quotes when a command also describes a target field.

Speech capture remains in `RealtimeSTT`, independent of Jev and the existing Codex runner. Final transcripts alone initiate actions. A failed or cancelled transcription never submits a provisional command. Speech target app is frozen before recording; no commands queue in Mac mode, so stale commands cannot execute after a later action.

## Execution evidence

- Opening an application verifies the returned process.
- New windows, closed windows, and inserted text are checked against fresh AX state where the app exposes it.
- Shortcut, scroll, and click receipts explicitly identify when only delivery is known.
- The driver does not retry uncertain input. Closing stops at modal/save dialogs and retains a bounded window list.
- Esc cancels the active network request and prevents subsequent actions. An already delivered action may remain visible.

Only the selected command, application inventory, and necessary control descriptions go to TypeSafe. Error responses are reduced to safe diagnostics; keys and response bodies are never logged. Screenshots and clipboard values are not part of Jev requests. Credentials stay in local `.env`/settings with mode `0600` and are excluded from Git, the app bundle, and managed Codex subprocesses.

## Validation

Run `swift test` and `./script/build_and_run.sh --build-only`. Tests cover typed requests, exact literals, malformed/unknown/low-confidence choices, cancellation, environment precedence, legacy session preservation, and Unicode insertion boundaries. Live Mac input additionally needs user-granted Accessibility permission; speech needs Microphone permission. Unit tests never operate the user's apps.

Sources: [TypeSafe API](https://docs.typesafe.ai/api), [models](https://docs.typesafe.ai/models), [function calling cookbook](https://docs.typesafe.ai/cookbooks/function_calling), and the [reference video](https://www.youtube.com/shorts/vSzde5be5XE).
