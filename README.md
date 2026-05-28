# screen-grab

A macOS menubar tool that drafts text into whatever field you're focused on — online forms, comment sections, email replies, chat boxes — in your own voice. Two hotkeys, two ways to start: dictate what you want, or let the model compose from what's already on screen.

## Setup

You need macOS 13+, Node 20+, and Swift 5.9+ (Command Line Tools is enough).

### 1. Build

```bash
cd screen-grab-brain && npm ci && cd ..
cd screen-grab-mac && swift test && ./scripts/build-app.sh release && cd ..
```

### 2. Configure your voice

```bash
cp -r voice.example voice
```

Edit:
- `voice/style.md` — how you write (tone, sentence length, banned phrases).
- `voice/about.md` — what you write about (background, proof points, hard rules). Optional but recommended; drafts feel generic without it.
- `voice/routing.json` — map (app, window title) → few-shot bucket under `voice/examples/`.

### 3. Configure the daemon

Create `~/.config/screen-grab/config.json`:

```json
{
  "backend": "anthropic-api",
  "model": "claude-opus-4-7",
  "hotkey": "RightCommand",
  "composeHotkey": "RightOption",
  "maxTokens": 600,
  "timeoutMs": 20000,
  "voiceDir": "/absolute/path/to/screen-grab/voice",
  "telemetryPath": "/absolute/path/to/screen-grab/voice/telemetry.jsonl"
}
```

Backends:
- `anthropic-api` — needs `ANTHROPIC_API_KEY`; pay per token.
- `claude-code-sdk` — uses your Claude Max subscription via `claude login`; no per-token cost.

For `anthropic-api`, put the key where launchd can find it:

```bash
echo 'ANTHROPIC_API_KEY=sk-ant-...' > .env.local
./screen-grab-mac/scripts/load-env.sh
```

### 4. Grant permissions

```bash
open screen-grab-mac/build/screen-grab.app
```

Then toggle screen-grab on in **System Settings → Privacy & Security**:

- **Accessibility** — global hotkey + read focused field.
- **Input Monitoring** — receive keystrokes (macOS Sequoia+).
- **Screen Recording** — fallback when accessibility can't read the field (browsers, Electron apps).
- **Microphone** + **Speech Recognition** — for the Dictate hotkey.

And **Keyboard → Dictation** must be toggled on system-wide (first enable downloads an on-device model).

> Permissions are tied to the app's signature. Every rebuild forces you to re-grant; this is a known limitation of ad-hoc signing. See [TROUBLESHOOT.md](TROUBLESHOOT.md#permissions-get-invalidated-on-every-rebuild).

### 5. Use it

Click in any text field, then:

| Hotkey | Field empty | Field already has text |
|---|---|---|
| **Right Cmd** (hold while speaking, release) — *Dictate* | Polish your dictation into the draft. | Continue the existing text in the direction of your dictation. |
| **Right Option** (hold ≥1s) — *Compose* | Draft from screen context + your `voice/about.md`. | Continue the existing text using screen context as direction. |

A HUD pops up bottom-center with the streaming draft. **Enter** pastes, **Cmd+R** regenerates, **Esc** dismisses.

## More

- [TROUBLESHOOT.md](TROUBLESHOOT.md) — common errors and fixes.
- [MANUAL_TESTS.md](MANUAL_TESTS.md) — end-to-end test recipes.
- `screen-grab-mac/scripts/doctor.sh` — preflight check that prints what's missing.
- `tail -f voice/telemetry.jsonl` — see every request + accept/edit/regenerate outcome.
