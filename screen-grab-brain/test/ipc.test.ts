import os from "node:os";
import path from "node:path";
import net from "node:net";
import fs from "node:fs/promises";
import { describe, it, expect, afterEach } from "vitest";
import { startIPCServer, type IPCServerHandle } from "../src/ipc.js";
import type { Config } from "../src/config.js";
import type { LLMBackend } from "../src/llm/backend.js";

function makeCfg(voiceDir: string): Config {
  return {
    backend: "anthropic-api",
    model: "claude-opus-4-7",
    hotkey: "RightCommand",
    maxTokens: 200,
    timeoutMs: 5000,
    voiceDir,
    telemetryPath: path.join(voiceDir, "telemetry.jsonl"),
    persistRawContext: false,
    axTextThreshold: 200,
    logLevel: "info",
  };
}

function makeFakeBackend(chunks: string[]): LLMBackend {
  return {
    name: "fake" as "anthropic-api",
    async *generate() {
      for (const text of chunks) {
        yield { type: "text" as const, delta: text };
      }
      yield { type: "done" as const, promptTokens: 100, completionTokens: 50 };
    },
  };
}

async function makeTmpVoice(): Promise<string> {
  const dir = path.join(os.tmpdir(), `ipc-voice-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await fs.mkdir(path.join(dir, "examples", "default"), { recursive: true });
  await fs.writeFile(path.join(dir, "style.md"), "Be concise.\n");
  await fs.writeFile(path.join(dir, "routing.json"), JSON.stringify([]));
  await fs.writeFile(
    path.join(dir, "examples", "default", "001.md"),
    "---\ncontext: example\naudience: peer\nlength: short\n---\n\nHi.\n",
  );
  return dir;
}

function readNDJSONLines(socket: net.Socket): { lines: AsyncIterable<unknown>; close: () => void } {
  let buf = "";
  const queue: unknown[] = [];
  let resolveNext: ((v: IteratorResult<unknown>) => void) | null = null;
  let ended = false;

  socket.on("data", (chunk) => {
    buf += chunk.toString("utf-8");
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line) continue;
      const obj = JSON.parse(line);
      if (resolveNext) {
        const r = resolveNext;
        resolveNext = null;
        r({ value: obj, done: false });
      } else {
        queue.push(obj);
      }
    }
  });
  socket.on("end", () => {
    ended = true;
    if (resolveNext) resolveNext({ value: undefined, done: true });
  });

  return {
    lines: {
      [Symbol.asyncIterator]() {
        return {
          next(): Promise<IteratorResult<unknown>> {
            if (queue.length) return Promise.resolve({ value: queue.shift()!, done: false });
            if (ended) return Promise.resolve({ value: undefined, done: true });
            return new Promise((resolve) => {
              resolveNext = resolve;
            });
          },
        };
      },
    },
    close: () => socket.end(),
  };
}

describe("IPC server — generate", () => {
  let handle: IPCServerHandle | null = null;

  afterEach(async () => {
    if (handle) await handle.close();
    handle = null;
  });

  it("forwards backend chunks as delta events and emits done", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const backend = makeFakeBackend(["Hey ", "Sarah."]);
    const sockPath = path.join(os.tmpdir(), `screen-grab-${Date.now()}.sock`);

    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));

    const reader = readNDJSONLines(sock);
    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "req-1",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );

    const events: { type: string; [k: string]: unknown }[] = [];
    for await (const ev of reader.lines) {
      const e = ev as { type: string; [k: string]: unknown };
      events.push(e);
      if (e.type === "done") break;
    }
    reader.close();

    expect(events.map((e) => e.type)).toEqual(["delta", "delta", "done"]);
    expect(events[0]).toMatchObject({ type: "delta", reqId: "req-1", text: "Hey " });
    expect(events[1]).toMatchObject({ type: "delta", reqId: "req-1", text: "Sarah." });
    expect(events[2]).toMatchObject({ type: "done", reqId: "req-1", promptTokens: 100, completionTokens: 50 });
  });

  it("emits an error event when the backend throws", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const backend: LLMBackend = {
      name: "throws" as "anthropic-api",
      // eslint-disable-next-line require-yield
      async *generate() {
        throw new Error("kaboom");
      },
    };
    const sockPath = path.join(os.tmpdir(), `screen-grab-err-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));
    const reader = readNDJSONLines(sock);
    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "req-err",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );

    const events: { type: string; [k: string]: unknown }[] = [];
    for await (const ev of reader.lines) {
      const e = ev as { type: string; [k: string]: unknown };
      events.push(e);
      if (e.type === "error") break;
    }
    reader.close();

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "error", reqId: "req-err" });
    expect(events[0].message).toContain("kaboom");
  });

  it("ignores malformed JSON lines without crashing", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const backend = makeFakeBackend(["ok"]);
    const sockPath = path.join(os.tmpdir(), `screen-grab-bad-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));
    const reader = readNDJSONLines(sock);

    sock.write("this is not json\n");
    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "req-after-garbage",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );

    const events: { type: string; [k: string]: unknown }[] = [];
    for await (const ev of reader.lines) {
      const e = ev as { type: string; [k: string]: unknown };
      events.push(e);
      if (e.type === "done") break;
    }
    reader.close();

    expect(events.map((e) => e.type)).toEqual(["delta", "done"]);
    expect(events[0]).toMatchObject({ reqId: "req-after-garbage", text: "ok" });
  });
});

describe("IPC server — feedback", () => {
  let handle: IPCServerHandle | null = null;

  afterEach(async () => {
    if (handle) await handle.close();
    handle = null;
  });

  it("appends a resolution row when feedback arrives", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const { telemetryPath } = cfg;
    const backend = makeFakeBackend(["draft text."]);
    const sockPath = path.join(os.tmpdir(), `screen-grab-fb-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));
    const reader = readNDJSONLines(sock);

    // First, run a generation so a pending row exists.
    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "req-fb",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );
    for await (const ev of reader.lines) {
      const e = ev as { type: string; [k: string]: unknown };
      if (e.type === "done") break;
    }

    // Now send feedback.
    sock.write(
      JSON.stringify({
        type: "feedback",
        reqId: "req-fb",
        event: "accepted",
        finalText: "draft text.",
        durationFromGenToCloseMs: 4321,
      }) + "\n",
    );

    // Poll for the resolution row instead of guessing a fixed delay.
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const content = await fs.readFile(telemetryPath, "utf-8").catch(() => "");
      if (content.trim().split("\n").filter(Boolean).length >= 2) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    reader.close();

    const lines = (await fs.readFile(telemetryPath, "utf-8")).trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0]!).outcome).toBe("pending");
    expect(JSON.parse(lines[1]!)).toMatchObject({
      reqId: "req-fb",
      outcome: "accepted",
      final: "draft text.",
      durationFromGenToCloseMs: 4321,
    });
  });

  it("appends a dismissed resolution with null final", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const { telemetryPath } = cfg;
    const backend = makeFakeBackend(["x"]);
    const sockPath = path.join(os.tmpdir(), `screen-grab-fb2-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));
    const reader = readNDJSONLines(sock);

    sock.write(
      JSON.stringify({
        type: "generate",
        reqId: "req-fb-d",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      }) + "\n",
    );
    for await (const ev of reader.lines) {
      const e = ev as { type: string; [k: string]: unknown };
      if (e.type === "done") break;
    }
    sock.write(
      JSON.stringify({
        type: "feedback",
        reqId: "req-fb-d",
        event: "dismissed",
        durationFromGenToCloseMs: 100,
      }) + "\n",
    );
    // Poll for the resolution row instead of guessing a fixed delay.
    const deadline2 = Date.now() + 2000;
    while (Date.now() < deadline2) {
      const content = await fs.readFile(telemetryPath, "utf-8").catch(() => "");
      if (content.trim().split("\n").filter(Boolean).length >= 2) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    reader.close();

    const lines = (await fs.readFile(telemetryPath, "utf-8")).trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[1]!)).toMatchObject({
      reqId: "req-fb-d",
      outcome: "dismissed",
      final: null,
      durationFromGenToCloseMs: 100,
    });
  });

  it("uses a single TelemetryLog instance across feedback messages on one connection", async () => {
    // Send 5 feedback messages and verify all 5 resolution rows land in order.
    // Today (with new TelemetryLog per call) this happens to work because each
    // call serializes via TelemetryLog's internal chain. After the refactor,
    // a single shared instance does the same. This test guards against either
    // path breaking ordering.
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const { telemetryPath } = cfg;
    const backend = makeFakeBackend(["x"]);
    const socketPath = path.join(os.tmpdir(), `screen-grab-fb-multi-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath, cfg, backend });

    const conn = net.createConnection(socketPath);
    await new Promise<void>((r) => conn.once("connect", () => r()));

    for (let i = 0; i < 5; i++) {
      conn.write(
        JSON.stringify({
          type: "feedback",
          reqId: `multi-${i}`,
          event: "dismissed",
          durationFromGenToCloseMs: i,
        }) + "\n",
      );
    }

    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const content = await fs.readFile(telemetryPath, "utf-8").catch(() => "");
      if (
        ["multi-0", "multi-1", "multi-2", "multi-3", "multi-4"].every((id) => content.includes(id))
      ) {
        break;
      }
      await new Promise((r) => setTimeout(r, 10));
    }

    conn.end();
    const lines = (await fs.readFile(telemetryPath, "utf-8")).trim().split("\n").filter(Boolean);
    const order = lines
      .map((l) => JSON.parse(l))
      .filter((r: { reqId?: string }) => r.reqId?.startsWith("multi-"))
      .map((r: { reqId: string }) => r.reqId);
    expect(order).toEqual(["multi-0", "multi-1", "multi-2", "multi-3", "multi-4"]);
  });

  it("appends a resolution with outcome=error when feedback event is error", async () => {
    const voiceDir = await makeTmpVoice();
    const cfg = makeCfg(voiceDir);
    const { telemetryPath } = cfg;
    const backend = makeFakeBackend(["x"]);
    const sockPath = path.join(os.tmpdir(), `screen-grab-fb-err-${Date.now()}.sock`);
    handle = await startIPCServer({ socketPath: sockPath, cfg, backend });

    const sock = net.createConnection({ path: sockPath });
    await new Promise<void>((r) => sock.once("connect", r));
    const reader = readNDJSONLines(sock);

    // No prior generate; daemon emits feedback{error} when brain reports
    // an error event for a reqId that may have no pending row in this run.
    sock.write(
      JSON.stringify({
        type: "feedback",
        reqId: "err-req-1",
        event: "error",
        durationFromGenToCloseMs: 1234,
      }) + "\n",
    );

    // Poll the telemetry file until the err-req-1 row appears.
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const content = await fs.readFile(telemetryPath, "utf-8").catch(() => "");
      if (content.includes("err-req-1")) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    reader.close();

    const lines = (await fs.readFile(telemetryPath, "utf-8")).trim().split("\n").filter(Boolean);
    const last = JSON.parse(lines[lines.length - 1]!);
    expect(last).toMatchObject({
      reqId: "err-req-1",
      outcome: "error",
      durationFromGenToCloseMs: 1234,
    });
  });
});
