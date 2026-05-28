import { describe, it, expect } from "vitest";
import { ClaudeCodeSDKBackend, type SDKQueryFn } from "../src/llm/claude-code-sdk.js";
import type { GenerateRequest } from "../src/llm/backend.js";

// Minimal subset of @anthropic-ai/claude-agent-sdk SDKMessage shapes the
// backend cares about. We mimic the real types just closely enough to drive
// the decoder without pulling the real SDK in (so the test doesn't depend on
// the optional native binary or real `claude` CLI auth).
type FakeSDKMessage =
  | {
      type: "assistant";
      message: { content: Array<{ type: "text"; text: string } | { type: string; [k: string]: unknown }> };
    }
  | {
      type: "stream_event";
      event:
        | {
            type: "content_block_delta";
            index: number;
            delta: { type: "text_delta"; text: string } | { type: string; [k: string]: unknown };
          }
        | { type: string; [k: string]: unknown };
    }
  | {
      type: "result";
      subtype: "success" | "error_during_execution";
      usage: { input_tokens: number; output_tokens: number };
    }
  | { type: "system" | "user" | string; [k: string]: unknown };

function fakeQuery(messages: FakeSDKMessage[]): SDKQueryFn {
  return (_opts) =>
    (async function* () {
      for (const m of messages) yield m;
    })();
}

describe("ClaudeCodeSDKBackend", () => {
  it("yields text deltas in order then a done chunk with token counts", async () => {
    // Production path: the backend asks for partial messages, so the SDK
    // emits stream_event deltas and a final result.
    const backend = new ClaudeCodeSDKBackend({
      queryImpl: fakeQuery([
        {
          type: "stream_event",
          event: {
            type: "content_block_delta",
            index: 0,
            delta: { type: "text_delta", text: "Hey " },
          },
        },
        {
          type: "stream_event",
          event: {
            type: "content_block_delta",
            index: 0,
            delta: { type: "text_delta", text: "Sarah," },
          },
        },
        {
          type: "result",
          subtype: "success",
          usage: { input_tokens: 100, output_tokens: 5 },
        },
      ]),
    });

    const req: GenerateRequest = {
      system: "you are a writing assistant",
      messages: [{ role: "user", content: [{ type: "text", text: "draft a reply" }] }],
      model: "claude-opus-4-7",
      maxTokens: 600,
    };

    const out: Array<{ type: string; delta?: string; promptTokens?: number; completionTokens?: number }> = [];
    for await (const chunk of backend.generate(req)) out.push(chunk);

    expect(out).toEqual([
      { type: "text", delta: "Hey " },
      { type: "text", delta: "Sarah," },
      { type: "done", promptTokens: 100, completionTokens: 5 },
    ]);
  });

  it("falls back to the full assistant message text when no stream_events are emitted", async () => {
    // Defensive path: if includePartialMessages is ignored (older CLI, etc.),
    // the SDK still emits a complete assistant message after the turn. We
    // yield its text as a single delta so the contract holds.
    const backend = new ClaudeCodeSDKBackend({
      queryImpl: fakeQuery([
        {
          type: "assistant",
          message: { content: [{ type: "text", text: "complete reply text" }] },
        },
        {
          type: "result",
          subtype: "success",
          usage: { input_tokens: 42, output_tokens: 4 },
        },
      ]),
    });

    const req: GenerateRequest = {
      system: "s",
      messages: [{ role: "user", content: [{ type: "text", text: "u" }] }],
      model: "claude-opus-4-7",
      maxTokens: 100,
    };

    const out: Array<{ type: string; delta?: string; promptTokens?: number; completionTokens?: number }> = [];
    for await (const chunk of backend.generate(req)) out.push(chunk);

    expect(out).toEqual([
      { type: "text", delta: "complete reply text" },
      { type: "done", promptTokens: 42, completionTokens: 4 },
    ]);
  });

  it("switches to AsyncIterable<SDKUserMessage> when an image content block is present", async () => {
    // Capture the prompt argument actually passed to query() so we can assert
    // on its shape — string vs. AsyncIterable.
    let capturedPrompt: unknown;
    const queryImpl: SDKQueryFn = (params) => {
      capturedPrompt = params.prompt;
      return (async function* () {
        yield { type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } } };
        yield { type: "result", subtype: "success", usage: { input_tokens: 1, output_tokens: 1 } };
      })();
    };
    const backend = new ClaudeCodeSDKBackend({ queryImpl });

    const req: GenerateRequest = {
      system: "s",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "draft a reply" },
            { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
          ],
        },
      ],
      model: "claude-opus-4-7",
      maxTokens: 100,
    };

    for await (const _ of backend.generate(req)) { void _; }

    // String form would mean images dropped. Iterable form is required.
    expect(typeof capturedPrompt).not.toBe("string");
    expect(capturedPrompt).toBeDefined();
    // Drain the iterable and inspect the one user message we emit.
    const iter = capturedPrompt as AsyncIterable<{ message: { content: unknown[] } }>;
    const yielded: Array<{ message: { content: unknown[] } }> = [];
    for await (const msg of iter) yielded.push(msg);
    expect(yielded).toHaveLength(1);
    const content = yielded[0]!.message.content;
    // One text + one image, in that order.
    expect(content).toHaveLength(2);
    expect((content[0] as { type: string }).type).toBe("text");
    expect((content[1] as { type: string; source: { data: string } }).type).toBe("image");
    expect((content[1] as { source: { data: string } }).source.data).toBe("AAAA");
  });

  it("name is the backend tag", () => {
    const backend = new ClaudeCodeSDKBackend({
      queryImpl: () => (async function* () {})(),
    });
    expect(backend.name).toBe("claude-code-sdk");
  });
});
