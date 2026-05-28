# Manual test matrix

The Swift daemon's hotkey/AX/HUD/insertion paths can't be fully exercised
by unit tests. This file is the canonical checklist to run before declaring
a Plan-2 build green.

## Prereqs

```bash
# 1. Brain dependencies installed and green.
cd screen-grab-brain
npm ci
npm test  # expect 36 passing

# 2. Voice files in place.
ls voice/ voice/style.md voice/routing.json voice/examples/

# 3. Daemon built.
cd ../screen-grab-mac
./scripts/build-app.sh release

# 4. ANTHROPIC_API_KEY exported in your shell or via launchd plist.
echo $ANTHROPIC_API_KEY  # non-empty

# 5. Accessibility permission granted to screen-grab.app.
#    First launch will fail with "Need Accessibility permission".
#    Grant: System Settings → Privacy & Security → Accessibility → screen-grab.

# 6. ~/.config/screen-grab/config.json exists with at least:
#    {
#      "backend": "anthropic-api",
#      "model": "claude-opus-4-7",
#      "hotkey": "RightCommand",
#      "maxTokens": 600,
#      "timeoutMs": 20000,
#      "voiceDir": "${repoRoot}/voice",
#      "telemetryPath": "${repoRoot}/voice/telemetry.jsonl",
#      "persistRawContext": false,
#      "axTextThreshold": 200,
#      "logLevel": "info"
#    }
#    (repoRoot defaults to ~/Documents/GitHub/screen-grab; brainBinPath defaults to
#     ~/Documents/GitHub/screen-grab/screen-grab-brain/bin/screen-grab-brain-ipc)
```

Launch:

```bash
open screen-grab-mac/build/screen-grab.app
```

Quit any time:

```bash
killall screen-grab-mac
```

## Hotkey checks (HotkeyListener)

| # | Action | Expected |
|---|---|---|
| H1 | Tap Right Cmd alone (~50 ms) | HUD appears |
| H2 | Hold Right Cmd > 500 ms then release | No HUD (hold-too-long; FSM threshold is 500 ms) |
| H3 | Hold Right Cmd, press another key, release | No HUD (cancelled by other keydown) |
| H4 | Tap Left Cmd alone | No HUD (wrong modifier) |
| H5 | Type a Cmd+letter combo (Cmd+C, Cmd+V, etc.) | No HUD; original combo still works in the target app |
| H6 | Edit `~/.config/screen-grab/config.json` to `"hotkey": "RightCommand+Space"`, relaunch | Right Cmd + Space fires; Right Cmd alone no longer fires |

## Capture checks (ContextCapture)

| # | Frontmost app + state | Expected `axTree` |
|---|---|---|
| C1 | Mail.app, in a "Reply" compose, focused in body | `focusedFieldRole=AXTextArea`; `focusedFieldText` reflects whatever's typed; sibling texts include "From", "Subject" |
| C2 | Notes.app, focused in a note | `focusedFieldRole=AXTextArea`; `focusedFieldText` reflects current note content |
| C3 | Chrome on a Gmail compose, focused in body | `focusedFieldRole=AXTextArea` (from the WebKit accessibility shim); some sibling texts present |
| C4 | Slack desktop, focused in a DM input | `focusedFieldRole` is a text field; sibling texts include some thread context |

Verify by checking Console.app logs (process `screen-grab-mac` or `screen-grab-brain-ipc`).
The brain's `voice/telemetry.jsonl` also contains the captured BrainRequest context
(via the `pending` row's `context.axTreeHash`; set `"persistRawContext": true` in config
for the full `axTree` in telemetry).

## HUD checks (HUDOverlay)

| # | Action | Expected |
|---|---|---|
| HUD1 | Tap hotkey | HUD appears bottom-center of the screen containing the focused window |
| HUD2 | Watch streaming | Each delta appends to the body; status label updates |
| HUD3 | Press Esc mid-stream | HUD vanishes; brain telemetry resolution row shows `outcome: "dismissed"` for that reqId |
| HUD4 | Wait for `done`, press Enter | HUD vanishes; draft pastes into focused field; brain telemetry resolution row shows `outcome: "accepted"` |
| HUD5 | Press Enter mid-stream | No paste yet; HUD shows `pendingAccept` (label still shows streaming); on `done` the paste fires automatically |
| HUD6 | Multi-monitor: drag focused window to second display, tap hotkey | HUD appears on the same display as the focused window |

## Insertion checks (TextInserter)

| # | App | Expected |
|---|---|---|
| I1 | Mail.app reply body | Pasted text replaces selection or appears at caret; clipboard restored ~150 ms later |
| I2 | Gmail compose in Chrome | Same |
| I3 | Slack DM input | Same |
| I4 | Notes.app | Same |
| I5 | Discord (Electron) | Same |

For each: before triggering, copy a known sentinel string to your clipboard.
After the paste lands, hit Cmd+V again — it should paste the sentinel, not the draft
(confirms clipboard was restored).

## End-to-end smoke

1. Open Mail.app, click Reply on any message.
2. Place the caret in the body.
3. Press the hotkey.
4. Verify the HUD appears, streams, and completes.
5. Press Enter.
6. Verify the draft is pasted into the body.
7. Verify `voice/telemetry.jsonl` has two new rows for that reqId:
   - first (`TelemetryRecord`): `"outcome": "pending"` with non-empty `draft` and real token counts
   - second (`TelemetryResolution`): `"outcome": "accepted"` with `final` set to the pasted text

```bash
tail -2 voice/telemetry.jsonl | jq .
```

Capture the smoke result (date, app, latency in ms, prompt/completion tokens) in
`HANDOFF.md` — matching the evidence format Plan 1's smoke produced.

## What's deliberately NOT tested in Plan 2

These are Plan 3 scope, not bugs:

- Cmd+R regenerate
- In-HUD edit (text becomes editable on focus)
- Screenshot+VLM fallback when AX tree is empty
- `claude-code-sdk` backend (uses Claude Max subscription instead of API key)
- launchd auto-start of brain (currently brain runs as daemon-managed child)
- Permissions onboarding UI (currently log + exit)

---

## Dictation (D1–D8) — slice 1

Run after building and granting Microphone + Speech Recognition permissions
(System Settings → Privacy & Security → Microphone / Speech Recognition).

| ID | Steps | Expected |
|---|---|---|
| D1 | Focus an empty Mail reply field. Hold Right Cmd, say "tell sarah I'll get back to her by friday", release. | HUD shows "Listening…" + meter while holding. After release, "Transcribing…" briefly, then "Heard: tell sarah …" header above streaming polished draft. Press Enter — polished draft pastes into Mail field. Telemetry row at `voice/telemetry.jsonl` has `spokenIntent: "tell sarah …"` and `transcriberName: "apple-speech"`. |
| D2 | Focus a text field. Hold Right Cmd, say nothing, release. | HUD shows "Didn't catch anything — try again". Esc dismisses. Telemetry row has `outcome: "error"`, `errorMessage: "empty_transcript"`. |
| D3 | In a Mail reply, type "Hi Sarah —" without sending. Hold Right Cmd, say "I can do friday at 3, lemme know if that works", release. | Polished draft begins from where "Hi Sarah —" left off (continuation prompt). Telemetry row: brain prompt should include "continue from where it ends". |
| D4 | Hold Right Cmd for >65 seconds while talking. | At 50s the `[audio] cap warning` log line appears. At 60s, capture auto-stops, normal `.transcribing` flow runs with the 60s of audio captured. |
| D5 | Open System Settings → Privacy & Security → Microphone, deny screen-grab. Restart app. Hold Right Cmd. | HUD shows "Need Microphone permission. System Settings → Privacy & Security → Microphone." Esc dismisses. |
| D6 | Re-grant Microphone. Then deny Speech Recognition. Hold Right Cmd, speak. | HUD shows "Need Speech Recognition permission. …" after release. |
| D7 | Hold Right Option for 1s. | Compose mode fires: HUD shows generating then ready, no transcript header (regression guard). |
| D8 | Disable Wi-Fi (or unplug Ethernet). Repeat D1. | Apple Speech on Apple Silicon falls back to on-device — should still produce a transcript and polished draft. |
| D9 | After D1 lands a polished draft, press Cmd+R to regenerate (before Enter). | HUD shows generating then ready again with a new draft. Telemetry row for the regen reqId has `spokenIntent` and `transcriberName` populated (regression guard for commit d43d544). |
