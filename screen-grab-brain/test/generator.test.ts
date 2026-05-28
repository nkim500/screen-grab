import { describe, it, expect, beforeEach } from "vitest";
import { mkdtemp, readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { generate, type BrainEvent } from "../src/generator.js";
import type { LLMBackend, GenerateChunk } from "../src/llm/backend.js";
import type { Config } from "../src/config.js";

class FakeBackend implements LLMBackend {
  readonly name = "anthropic-api" as const;
  constructor(private chunks: GenerateChunk[]) {}
  async *generate(): AsyncIterable<GenerateChunk> {
    for (const c of this.chunks) yield c;
  }
}

async function makeVoiceFixture(root: string): Promise<void> {
  await mkdir(path.join(root, "examples/gmail-work"), { recursive: true });
  await writeFile(path.join(root, "style.md"), "I write short, direct sentences.");
  await writeFile(
    path.join(root, "examples/gmail-work/001.md"),
    "---\ncontext: 'reply'\naudience: 'peer'\nlength: 'short'\n---\nhey, sounds good.",
  );
  await writeFile(
    path.join(root, "routing.json"),
    JSON.stringify([{ match: { app: "Mail" }, bucket: "gmail-work" }]),
  );
}

let tmp: string;
let cfg: Config;

beforeEach(async () => {
  tmp = await mkdtemp(path.join(os.tmpdir(), "gen-"));
  await makeVoiceFixture(tmp);
  cfg = {
    backend: "anthropic-api",
    model: "claude-opus-4-7",
    hotkey: "RightCommand",
    maxTokens: 100,
    timeoutMs: 5000,
    voiceDir: tmp,
    telemetryPath: path.join(tmp, "telemetry.jsonl"),
    persistRawContext: false,
    axTextThreshold: 200,
    logLevel: "info",
  };
});

describe("generate", () => {
  it("streams text deltas in order then a done event", async () => {
    const backend = new FakeBackend([
      { type: "text", delta: "hey " },
      { type: "text", delta: "sarah." },
      { type: "done", promptTokens: 50, completionTokens: 5 },
    ]);

    const events: BrainEvent[] = [];
    for await (const ev of generate(
      {
        reqId: "r1",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: {
          focusedFieldRole: "AXTextArea",
          focusedFieldText: "",
          siblingTexts: [],
        },
      },
      cfg,
      backend,
    )) {
      events.push(ev);
    }

    const texts = events.filter((e) => e.type === "delta").map((e) => (e as { text: string }).text);
    expect(texts.join("")).toBe("hey sarah.");
    expect(events[events.length - 1]!.type).toBe("done");
  });

  it("writes a telemetry record at the end with outcome 'pending'", async () => {
    const backend = new FakeBackend([
      { type: "text", delta: "hi" },
      { type: "done", promptTokens: 10, completionTokens: 1 },
    ]);

    for await (const _ of generate(
      {
        reqId: "r2",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      },
      cfg,
      backend,
    )) {
      // drain
    }

    const text = await readFile(cfg.telemetryPath, "utf-8");
    const record = JSON.parse(text.trim());
    expect(record.reqId).toBe("r2");
    expect(record.draft).toBe("hi");
    expect(record.outcome).toBe("pending"); // outcome is finalized later via feedback
    expect(record.promptTokens).toBe(10);
    expect(record.completionTokens).toBe(1);
  });

  it("yields an error event and writes outcome 'error' if backend throws", async () => {
    class ThrowingBackend implements LLMBackend {
      readonly name = "anthropic-api" as const;
      // eslint-disable-next-line require-yield
      async *generate(): AsyncIterable<GenerateChunk> {
        throw new Error("boom");
      }
    }

    const events: BrainEvent[] = [];
    for await (const ev of generate(
      {
        reqId: "r3",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      },
      cfg,
      new ThrowingBackend(),
    )) {
      events.push(ev);
    }

    expect(events.some((e) => e.type === "error")).toBe(true);
    const text = await readFile(cfg.telemetryPath, "utf-8");
    const record = JSON.parse(text.trim());
    expect(record.outcome).toBe("error");
    expect(record.errorMessage).toMatch(/boom/);
  });

  it("writes telemetry even if consumer breaks after done", async () => {
    const backend = new FakeBackend([
      { type: "text", delta: "hi" },
      { type: "done", promptTokens: 7, completionTokens: 2 },
    ]);

    for await (const ev of generate(
      {
        reqId: "r4",
        app: "Mail",
        windowTitle: "Reply",
        intent: "draft",
        axTree: { focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [] },
      },
      cfg,
      backend,
    )) {
      if (ev.type === "done") break; // consumer abandons immediately after done
    }

    // The for-await loop awaits iterator.return(), which runs the generator's finally
    // block, so the telemetry write should have completed before we get here.
    const text = await readFile(cfg.telemetryPath, "utf-8");
    const record = JSON.parse(text.trim());
    expect(record.reqId).toBe("r4");
    expect(record.outcome).toBe("pending");
    expect(record.draft).toBe("hi");
  });
});
