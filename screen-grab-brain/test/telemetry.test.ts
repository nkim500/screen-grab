import { describe, it, expect, beforeEach, vi } from "vitest";
import { TelemetryLog, type TelemetryRecord, type TelemetryResolution } from "../src/telemetry.js";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";

let dir: string;
let logPath: string;

beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), "tlm-"));
  logPath = path.join(dir, "telemetry.jsonl");
});

const sample = (overrides: Partial<TelemetryRecord> = {}): TelemetryRecord => ({
  reqId: "abc",
  ts: "2026-05-08T14:33:01Z",
  app: "Mail",
  windowTitle: "Reply",
  intent: "draft",
  context: { axTreeHash: "sha256:x", screenshotHash: null },
  voice: { styleHash: "sha256:y", exampleFiles: ["a.md"] },
  model: "claude-opus-4-7",
  backend: "anthropic-api",
  promptTokens: 100,
  completionTokens: 50,
  latencyMs: 1000,
  draft: "hello",
  outcome: "accepted",
  final: "hello",
  editDistance: 0,
  durationFromGenToCloseMs: 5000,
  spokenIntent: null,
  transcriberName: null,
  ...overrides,
});

describe("TelemetryLog", () => {
  it("appends one JSONL record per call", async () => {
    const log = new TelemetryLog(logPath);
    await log.append(sample());
    const text = await readFile(logPath, "utf-8");
    expect(text).toMatch(/\n$/);
    const lines = text.trim().split("\n");
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]!);
    expect(parsed.reqId).toBe("abc");
    expect(parsed.outcome).toBe("accepted");
  });

  it("appends multiple records as separate lines", async () => {
    const log = new TelemetryLog(logPath);
    await log.append(sample({ reqId: "1" }));
    await log.append(sample({ reqId: "2" }));
    await log.append(sample({ reqId: "3" }));
    const text = await readFile(logPath, "utf-8");
    const lines = text.trim().split("\n");
    expect(lines).toHaveLength(3);
    expect(lines.map((l) => JSON.parse(l).reqId)).toEqual(["1", "2", "3"]);
  });

  it("serializes concurrent appends without interleaving", async () => {
    const log = new TelemetryLog(logPath);
    await Promise.all(
      Array.from({ length: 20 }, (_, i) => log.append(sample({ reqId: `r${i}` }))),
    );
    const text = await readFile(logPath, "utf-8");
    const lines = text.trim().split("\n");
    expect(lines).toHaveLength(20);
    // Each line must parse cleanly — no torn writes.
    for (const line of lines) {
      expect(() => JSON.parse(line)).not.toThrow();
    }
  });

  it("does not poison the chain when a write fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      // Point the log at a path under a file (so mkdir parent fails).
      const blockerFile = path.join(dir, "blocker");
      await writeFile(blockerFile, "x");
      const badPath = path.join(blockerFile, "telemetry.jsonl");
      const badLog = new TelemetryLog(badPath);

      // First append: write fails internally, but append() must not reject.
      await expect(badLog.append(sample({ reqId: "fail-1" }))).resolves.toBeUndefined();
      // Second append: chain not poisoned, append() still resolves.
      await expect(badLog.append(sample({ reqId: "fail-2" }))).resolves.toBeUndefined();

      // A separate log on a good path still works fine after failures elsewhere.
      const goodLog = new TelemetryLog(logPath);
      await goodLog.append(sample({ reqId: "ok" }));
      const text = await readFile(logPath, "utf-8");
      expect(text.trim().split("\n")).toHaveLength(1);
    } finally {
      errorSpy.mockRestore();
    }
  });
});

describe("TelemetryLog.appendResolution", () => {
  it("appends a JSONL line with the resolution shape", async () => {
    const tmp = path.join(os.tmpdir(), `telemetry-res-${Date.now()}.jsonl`);
    const log = new TelemetryLog(tmp);

    const resolution: TelemetryResolution = {
      reqId: "req-1",
      ts: "2026-05-09T12:00:00.000Z",
      outcome: "accepted",
      final: "Hey Sarah — sending notes tomorrow.",
      durationFromGenToCloseMs: 12345,
    };
    await log.appendResolution(resolution);

    const text = await readFile(tmp, "utf-8");
    const lines = text.trim().split("\n");
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]!);
    expect(parsed).toMatchObject({
      reqId: "req-1",
      outcome: "accepted",
      final: "Hey Sarah — sending notes tomorrow.",
      durationFromGenToCloseMs: 12345,
    });
    // Resolution rows are distinguishable from full records by absence of `intent`.
    expect(parsed.intent).toBeUndefined();
  });

  it("appends after pending in chain order", async () => {
    const tmp = path.join(os.tmpdir(), `telemetry-chain-${Date.now()}.jsonl`);
    const log = new TelemetryLog(tmp);

    const pending: TelemetryRecord = {
      reqId: "req-2",
      ts: "2026-05-09T12:00:00.000Z",
      app: "Mail",
      windowTitle: "Reply",
      intent: "draft",
      context: { axTreeHash: null, screenshotHash: null },
      voice: { styleHash: "", exampleFiles: [] },
      model: "claude-opus-4-7",
      backend: "anthropic-api",
      promptTokens: 0,
      completionTokens: 0,
      latencyMs: 0,
      draft: "",
      outcome: "pending",
      final: null,
      editDistance: null,
      durationFromGenToCloseMs: null,
      spokenIntent: null,
      transcriberName: null,
    };
    const resolved: TelemetryResolution = {
      reqId: "req-2",
      ts: "2026-05-09T12:00:13.000Z",
      outcome: "dismissed",
      final: null,
      durationFromGenToCloseMs: 13000,
    };

    // Fire both without awaiting in between; chain must serialize.
    const a = log.append(pending);
    const b = log.appendResolution(resolved);
    await Promise.all([a, b]);

    const lines = (await readFile(tmp, "utf-8")).trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0]!).outcome).toBe("pending");
    expect(JSON.parse(lines[1]!).outcome).toBe("dismissed");
  });

  it("does not poison chain on write error", async () => {
    const log = new TelemetryLog("/dev/null/cant-write/here.jsonl");
    await expect(
      log.appendResolution({
        reqId: "x",
        ts: "2026-05-09T12:00:00.000Z",
        outcome: "accepted",
        final: "x",
        durationFromGenToCloseMs: 1,
      }),
    ).resolves.toBeUndefined();
  });
});

describe("TelemetryRecord dictation fields", () => {
  it("includes spokenIntent and transcriberName when present", async () => {
    const p = path.join(os.tmpdir(), `tlm-dict-${Date.now()}.jsonl`);
    const log = new TelemetryLog(p);
    const record: TelemetryRecord = {
      reqId: "r-dict-1",
      ts: new Date().toISOString(),
      app: "Mail",
      windowTitle: "Reply",
      intent: "draft",
      context: { axTreeHash: "sha256:abc", screenshotHash: null },
      voice: { styleHash: "sha256:xyz", exampleFiles: [] },
      model: "claude-opus-4-7",
      backend: "anthropic-api",
      promptTokens: 10,
      completionTokens: 5,
      latencyMs: 800,
      draft: "Hello.",
      outcome: "pending",
      final: null,
      editDistance: null,
      durationFromGenToCloseMs: null,
      spokenIntent: "say hi to sarah",
      transcriberName: "apple-speech",
    };
    await log.append(record);
    const text = await readFile(p, "utf-8");
    const parsed = JSON.parse(text.trim().split("\n")[0]!);
    expect(parsed.spokenIntent).toBe("say hi to sarah");
    expect(parsed.transcriberName).toBe("apple-speech");
  });

  it("writes spokenIntent and transcriberName as null for compose records", async () => {
    const p = path.join(os.tmpdir(), `tlm-cold-${Date.now()}.jsonl`);
    const log = new TelemetryLog(p);
    const record: TelemetryRecord = {
      reqId: "r-cold-1",
      ts: new Date().toISOString(),
      app: "Mail",
      windowTitle: "Reply",
      intent: "draft",
      context: { axTreeHash: "sha256:abc", screenshotHash: null },
      voice: { styleHash: "sha256:xyz", exampleFiles: [] },
      model: "claude-opus-4-7",
      backend: "anthropic-api",
      promptTokens: 10,
      completionTokens: 5,
      latencyMs: 800,
      draft: "Hello.",
      outcome: "pending",
      final: null,
      editDistance: null,
      durationFromGenToCloseMs: null,
      spokenIntent: null,
      transcriberName: null,
    };
    await log.append(record);
    const text = await readFile(p, "utf-8");
    const parsed = JSON.parse(text.trim().split("\n")[0]!);
    expect(parsed.spokenIntent).toBeNull();
    expect(parsed.transcriberName).toBeNull();
  });
});
