import os from "node:os";
import path from "node:path";
import net from "node:net";
import fs from "node:fs/promises";
import { spawn, type ChildProcess } from "node:child_process";
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import http from "node:http";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "../..");
const BRAIN_DIR = path.join(REPO_ROOT, "screen-grab-brain");

// Tiny localhost stand-in for the Anthropic API. Mirrors cli.e2e.test.ts pattern.
function startFakeAnthropic(): Promise<{ url: string; close: () => Promise<void> }> {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.url?.endsWith("/v1/messages")) {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
        });
        const events = [
          { event: "message_start", data: { type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", content: [], model: "claude-opus-4-7", stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } } } },
          { event: "content_block_start", data: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
          { event: "content_block_delta", data: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } } },
          { event: "content_block_delta", data: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: " world" } } },
          { event: "content_block_stop", data: { type: "content_block_stop", index: 0 } },
          { event: "message_delta", data: { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 2 } } },
          { event: "message_stop", data: { type: "message_stop" } },
        ];
        for (const e of events) {
          res.write(`event: ${e.event}\ndata: ${JSON.stringify(e.data)}\n\n`);
        }
        res.end();
        return;
      }
      res.writeHead(404).end();
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      resolve({
        url: `http://127.0.0.1:${port}`,
        close: () =>
          new Promise<void>((r) => {
            server.close(() => r());
          }),
      });
    });
  });
}

async function makeTmpVoice(): Promise<string> {
  const dir = path.join(os.tmpdir(), `e2e-voice-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await fs.mkdir(path.join(dir, "examples", "default"), { recursive: true });
  await fs.writeFile(path.join(dir, "style.md"), "Be concise.\n");
  // routing.json must be a flat array per the RoutingSchema (RuleSchema[]). The plan's
  // wrapper-object shape was a typo — using [] is the correct empty-rules state.
  await fs.writeFile(path.join(dir, "routing.json"), JSON.stringify([]));
  await fs.writeFile(
    path.join(dir, "examples", "default", "001.md"),
    "---\ncontext: example\naudience: peer\nlength: short\n---\n\nHi.\n",
  );
  return dir;
}

describe("IPC bin entry — cross-process round-trip", () => {
  let child: ChildProcess | null = null;
  let fake: { url: string; close: () => Promise<void> } | null = null;
  let socketPath = "";
  let voiceDir = "";
  let stdoutBuf = "";

  beforeAll(async () => {
    fake = await startFakeAnthropic();
    voiceDir = await makeTmpVoice();
    const cfg = {
      backend: "anthropic-api",
      model: "claude-opus-4-7",
      hotkey: "RightCommand",
      maxTokens: 50,
      timeoutMs: 5000,
      voiceDir,
      telemetryPath: path.join(voiceDir, "telemetry.jsonl"),
      persistRawContext: false,
      axTextThreshold: 200,
      logLevel: "info",
      baseURL: fake.url,
    };
    const cfgPath = path.join(voiceDir, "config.json");
    await fs.writeFile(cfgPath, JSON.stringify(cfg));
    socketPath = path.join(os.tmpdir(), `e2e-${Date.now()}.sock`);

    child = spawn(
      process.execPath,
      ["--import", "tsx", path.join(BRAIN_DIR, "src/ipc.ts"), "--config", cfgPath, "--socket", socketPath],
      {
        env: { ...process.env, ANTHROPIC_API_KEY: "test-key", REPO_ROOT },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    child.stderr?.setEncoding("utf-8");
    child.stdout?.setEncoding("utf-8");

    // Capture stdout from spawn time so the READY readiness token assertion
    // (below) can observe it regardless of when the listener attaches.
    child.stdout?.on("data", (chunk: string) => {
      stdoutBuf += chunk;
    });

    // Wait for "listening on" log line.
    await new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("brain ipc didn't start in time")), 8000);
      child!.stderr?.on("data", (chunk: string) => {
        if (chunk.includes("listening on")) {
          clearTimeout(t);
          resolve();
        }
      });
    });
  }, 15000);

  afterAll(async () => {
    if (child) {
      child.kill("SIGTERM");
      await new Promise<void>((r) => child!.once("exit", r));
    }
    if (fake) await fake.close();
  });

  it("round-trips a generate request through the bin entry", async () => {
    const sock = net.createConnection({ path: socketPath });
    await new Promise<void>((r) => sock.once("connect", r));

    let buf = "";
    const events: { type: string; [k: string]: unknown }[] = [];
    sock.setEncoding("utf-8");
    const done = new Promise<void>((resolve) => {
      sock.on("data", (chunk: string) => {
        buf += chunk;
        let nl: number;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (!line) continue;
          const ev = JSON.parse(line);
          events.push(ev);
          if (ev.type === "done") resolve();
        }
      });
    });

    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "e2e-1",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );
    await done;
    sock.end();

    expect(events.map((e) => e.type)).toEqual(["delta", "delta", "done"]);
    expect(events[0]).toMatchObject({ reqId: "e2e-1", text: "Hello" });
    expect(events[1]).toMatchObject({ reqId: "e2e-1", text: " world" });
  }, 20000);

  it("emits READY\\n on stdout once the IPC server is listening", () => {
    // The brain must print exactly one machine-readable readiness token on
    // stdout once it is safe for clients to connect. The daemon parses this
    // (rather than substring-matching the human stderr log) to know the IPC
    // socket is up. By the time beforeAll resolves the stderr "listening on"
    // line was already observed, so READY must already be in stdoutBuf.
    expect(stdoutBuf).toContain("READY\n");
  });
});
