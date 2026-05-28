import { describe, it, expect, beforeAll, afterAll, afterEach } from "vitest";
import { setupServer } from "msw/node";
import { http, HttpResponse } from "msw";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AnthropicAPIBackend } from "../src/llm/anthropic-api.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(__dirname, "fixtures/anthropic-stream.txt");

let streamBody: string;
const server = setupServer();

beforeAll(async () => {
  streamBody = await readFile(FIXTURE, "utf-8");
  server.listen({ onUnhandledRequest: "error" });
});
afterEach(() => server.resetHandlers());
afterAll(() => server.close());

describe("AnthropicAPIBackend", () => {
  it("yields text deltas in order then a done event", async () => {
    server.use(
      http.post("https://api.anthropic.com/v1/messages", () => {
        return new HttpResponse(streamBody, {
          headers: { "Content-Type": "text/event-stream" },
        });
      }),
    );

    const backend = new AnthropicAPIBackend({ apiKey: "test" });
    const chunks: Array<{ type: string; delta?: string }> = [];
    for await (const c of backend.generate({
      system: "s",
      messages: [{ role: "user", content: [{ type: "text", text: "u" }] }],
      model: "claude-opus-4-7",
      maxTokens: 100,
    })) {
      chunks.push(c);
    }

    const texts = chunks.filter((c) => c.type === "text").map((c) => c.delta);
    expect(texts.join("")).toBe("hey sarah, thanks for the note.");
    expect(chunks[chunks.length - 1]!.type).toBe("done");
  });

  it("propagates 429 as an error", async () => {
    server.use(
      http.post("https://api.anthropic.com/v1/messages", () => {
        return HttpResponse.json(
          { type: "error", error: { type: "rate_limit_error", message: "Rate limited" } },
          { status: 429 },
        );
      }),
    );

    const backend = new AnthropicAPIBackend({ apiKey: "test" });
    await expect(async () => {
      for await (const _ of backend.generate({
        system: "s",
        messages: [{ role: "user", content: [{ type: "text", text: "u" }] }],
        model: "claude-opus-4-7",
        maxTokens: 100,
      })) {
        // drain
      }
    }).rejects.toThrow();
  });
});
