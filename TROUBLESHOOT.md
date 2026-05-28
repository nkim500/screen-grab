# Troubleshooting

Common problems and their fixes. Run `./screen-grab-mac/scripts/doctor.sh` first — it checks the seven hard preconditions (launchd env, node, config, brain bin, dependencies, built app, TCC state) and prints a fix hint for each.

## Permissions

### Permissions get invalidated on every rebuild

Every `build-app.sh release` produces a new code signature, and macOS treats that as a new app. Accessibility, Input Monitoring, Screen Recording, Microphone, and Speech Recognition all need to be toggled off-and-back-on after each rebuild.

This is a limitation of ad-hoc code signing (no Apple Developer ID). Permanent fix is enrolling in the Apple Developer Program ($99/yr) and signing with Developer ID; nothing in the repo can work around it.

### `HUD shows "Need Accessibility permission"`

The daemon couldn't read the focused field via the accessibility API. Open the panel and toggle screen-grab on:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

### `HUD shows "Need Screen Recording permission"`

This appears when the accessibility read failed (which is normal in browsers, Electron apps, Gmail compose) AND the screenshot fallback also failed because Screen Recording isn't granted. Open:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

### `HUD shows "Need Microphone permission"` or `"Need Speech Recognition permission"`

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
```

If screen-grab-mac isn't listed, click `+` and select the .app bundle.

### `Speech recognition failed: kLSRErrorDomain Code=201 "Siri and Dictation are disabled"`

System-wide Dictation is off. `SFSpeechRecognizer` requires it on top of the app-level Speech Recognition TCC grant.

```bash
open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
```

Scroll to **Dictation** and toggle it on. First enable downloads an on-device model — wait for it to finish before retrying.

## Hotkeys

### Hotkey does nothing

- Check telemetry: `tail voice/telemetry.jsonl`. If new rows appear after a tap, the hotkey + brain are working and the issue is HUD visibility.
- If no rows: confirm screen-grab is in **both** Accessibility and Input Monitoring lists, toggled on.

### Dictate (Right Cmd) does nothing but Compose (Right Option) works

Microphone or Speech Recognition TCC grant is missing — Dictate needs both; Compose needs neither. The HUD should surface this as a "Need …" error, but if it doesn't, check the system log for `permissionDenied`:

```bash
log stream --process screen-grab-mac --style compact
```

### Enter / Esc / Cmd+R do nothing until you click the HUD

Fixed in PR #5 (commit `d0ad69d`). If you see this on an older build, rebuild from latest.

## Brain / runtime

### `[brain stderr] Cannot find package 'tsx'`

The daemon-spawned brain isn't `cd`ing into `screen-grab-brain/`. The `bin/screen-grab-brain-ipc` wrapper does this on current main; pull latest.

### `[brain stderr] node: command not found`

launchd's PATH doesn't include node. Re-run the env loader:

```bash
./screen-grab-mac/scripts/load-env.sh
# verify:
launchctl getenv PATH
```

Or run the daemon foreground from a shell that has node:

```bash
./screen-grab-mac/scripts/run.sh
```

### `[brain fatal] ANTHROPIC_API_KEY not set`

Same root cause as above — launchd's env doesn't have your API key. Put it in `.env.local` at the repo root and re-run `load-env.sh`. The `claude-code-sdk` backend avoids this entirely.

### `sg` menubar item doesn't appear

`applicationDidFinishLaunching` failed before the menubar install. Check the log:

```bash
log show --predicate 'process == "screen-grab-mac"' --last 5m --style compact | grep "screen-grab"
```

The `[screen-grab] up. hotkey=…` line is the success marker.

## Dictation specifics

### Dictate captures audio but produces "No speech detected"

The log line `[audio] stop bytes=… rms=…` tells you what to look at:

- **rms < 0.001** — buffer is silent. Wrong input device or hardware-muted mic. Check **System Settings → Sound → Input**.
- **rms > 0.02 and you still see "No speech detected"** — Apple Speech rejected the audio. The daemon auto-retries via server-side recognition; if that also fails, your `Locale.current` may not match the language you spoke, or whisper.cpp (Slice 2) will be a more robust fallback.

### `bytes=6400` regardless of how long I hold the key

Pre-`aac7446` bug where the converter was draining itself per-buffer. Pull latest and rebuild.

### Drafts duplicate the existing field text

Pre-`f946fe7` bug where the model echoed the seed text. Now both the prompt instructs against it and the daemon strips an exact-prefix match before paste. If you still see partial duplication (model paraphrased the prefix instead of repeating it verbatim), tighten `voice/style.md` or open an issue with the input/output pair.

## Diagnostic commands

```bash
# Real-time log filtered to screen-grab's tags
log stream --process screen-grab-mac --style compact | grep -E '\[(audio|stt|ctx|hk|hud)\]'

# Confirm daemon + brain are alive
pgrep -fl screen-grab

# Confirm the IPC socket exists
ls -la ~/.screen-grab.sock

# Latest telemetry
tail -5 voice/telemetry.jsonl
```
