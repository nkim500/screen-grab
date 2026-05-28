# screen-grab-brain

The brain process for screen-grab. Loads voice files, builds prompts, calls an LLM backend, streams output, logs telemetry.

In v0.1 (Plan 1) it ships as a CLI: pipe in a context JSON, get back streamed text on stdout. In Plan 2 (Daemon MVP) it'll add an IPC server alongside the CLI.

## Setup

1. Copy the voice template:
   ```bash
   cp -r ../voice.example ../voice
   ```
   Then edit `../voice/style.md` and add your own examples under `../voice/examples/<bucket>/`.

2. Write `~/.config/screen-grab/config.json` (see `config.example.json` if present, or use this minimal version):
   ```json
   {
     "backend": "anthropic-api",
     "model": "claude-opus-4-7",
     "voiceDir": "${repoRoot}/voice",
     "telemetryPath": "${repoRoot}/voice/telemetry.jsonl"
   }
   ```

3. Install and build:
   ```bash
   npm install
   npm run build
   ```

## Run

```bash
ANTHROPIC_API_KEY=sk-... REPO_ROOT=$(pwd)/.. \
  ./bin/screen-grab-brain --config ~/.config/screen-grab/config.json < context.json
```

`context.json` shape: see `test/fixtures/context-gmail.json`.

## IPC mode (Plan 2)

For use by the Swift daemon. Boots a long-lived Unix socket server.

```bash
ANTHROPIC_API_KEY=... \
  ./bin/screen-grab-brain-ipc \
  --config ~/.config/screen-grab/config.json \
  --socket ~/.screen-grab.sock
```

The daemon spawns this process on launch (see `screen-grab-mac/`).
SIGTERM exits gracefully and removes the socket file.

## Develop

```bash
npm install
npm run typecheck
npm test
```
