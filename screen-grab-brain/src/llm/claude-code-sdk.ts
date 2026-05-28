/**
 * ClaudeCodeSDKBackend
 * --------------------
 * Second `LLMBackend` implementation. Delegates to the user's local `claude`
 * CLI via the `@anthropic-ai/claude-agent-sdk` package — the package was
 * renamed from `@anthropic-ai/claude-code` in late 2025. Authenticates via the
 * cached `claude login` session, so no API key is required.
 *
 * SDK reality (verified against @anthropic-ai/claude-agent-sdk@0.2.138):
 *   - `query({ prompt, options })` returns a `Query` that extends
 *     `AsyncGenerator<SDKMessage, void>`.
 *   - `prompt` accepts `string | AsyncIterable<SDKUserMessage>`. We flatten
 *     `req.system + req.messages` into a single string prompt — the system
 *     prompt itself is also passed via `options.systemPrompt` so the model
 *     gets it in the canonical slot.
 *   - With `options.includePartialMessages: true`, the SDK emits
 *     `{ type: "stream_event", event: BetaRawMessageStreamEvent }` messages
 *     during streaming. We watch for `event.type === "content_block_delta"`
 *     with `event.delta.type === "text_delta"` and yield the `delta.text`
 *     as our `text` chunk — same shape AnthropicAPIBackend produces.
 *   - When partial messages aren't emitted (older CLI, or some control
 *     paths), the SDK still emits a complete `assistant` message after the
 *     turn with `message.content` = `Array<BetaContentBlock>`. We fall back
 *     to yielding the joined text from those text blocks as a single delta.
 *   - The terminal `{ type: "result" }` message carries `usage` with
 *     snake_case `input_tokens` / `output_tokens` (it's the upstream
 *     `BetaUsage` shape, not the camelCase `ModelUsage` shape).
 *   - Tools are disabled via `options.tools = []` (empty array = disable all
 *     built-in tools). `permissionMode: "dontAsk"` ensures any escape hatch
 *     deny-by-default rather than prompt the user.
 *
 * Test seam: the constructor accepts an optional `queryImpl` that mirrors the
 * SDK's `query()` signature, so tests can inject a fake without loading the
 * real SDK module (which pulls a native binary and the `claude` CLI). When
 * `queryImpl` is omitted, the real SDK is lazy-imported on first generate()
 * call so that importing this file in environments without the SDK installed
 * does not crash at module-load time.
 */

import type { GenerateRequest, GenerateChunk, LLMBackend } from "./backend.js";

// We deliberately avoid `import type` from the real SDK module so the build
// doesn't depend on it being installed. Below we use minimal local shapes —
// they're a subset of the real SDK types and would compile against either.

interface SDKQueryParams {
  // The real SDK accepts `string | AsyncIterable<SDKUserMessage>`. We need the
  // iterable form when sending images, since the string form has no place to
  // attach an image block. Typed as `unknown` for the iterable arm so we don't
  // pull SDKUserMessage shape into our minimal type surface.
  prompt: string | AsyncIterable<unknown>;
  options?: SDKQueryOptions;
}

interface SDKQueryOptions {
  abortController?: AbortController;
  model?: string;
  systemPrompt?: string;
  includePartialMessages?: boolean;
  maxTurns?: number;
  tools?: string[];
  permissionMode?: "default" | "dontAsk";
  // The real SDK has many more options; we only set what we use.
  [k: string]: unknown;
}

// Minimal SDKMessage variants we decode. Anything else is ignored.
type SDKMessageLike =
  | {
      type: "assistant";
      message: { content: Array<{ type: string; text?: string; [k: string]: unknown }> };
    }
  | {
      type: "stream_event";
      event: {
        type: string;
        delta?: { type: string; text?: string; [k: string]: unknown };
        [k: string]: unknown;
      };
    }
  | {
      type: "result";
      subtype: "success" | string;
      usage: { input_tokens: number; output_tokens: number; [k: string]: unknown };
      [k: string]: unknown;
    }
  | { type: string; [k: string]: unknown };

export type SDKQueryFn = (params: SDKQueryParams) => AsyncIterable<SDKMessageLike>;

export interface ClaudeCodeSDKBackendOptions {
  /** Test seam: inject a fake `query` function. Production omits this. */
  queryImpl?: SDKQueryFn;
}

export class ClaudeCodeSDKBackend implements LLMBackend {
  readonly name = "claude-code-sdk" as const;
  private readonly queryImpl?: SDKQueryFn;

  constructor(opts: ClaudeCodeSDKBackendOptions = {}) {
    this.queryImpl = opts.queryImpl;
  }

  private async loadQuery(): Promise<SDKQueryFn> {
    if (this.queryImpl) return this.queryImpl;
    // Lazy-load so test/CI environments without the SDK installed don't crash
    // when this module is imported (e.g. via ipc.ts).
    const mod = (await import("@anthropic-ai/claude-agent-sdk")) as { query: SDKQueryFn };
    return mod.query;
  }

  async *generate(req: GenerateRequest): AsyncIterable<GenerateChunk> {
    const query = await this.loadQuery();

    // If any message carries an image content block we must use the
    // AsyncIterable<SDKUserMessage> form — the string-prompt path has nowhere
    // to attach images. Otherwise prefer the cheaper string form.
    const hasImage = req.messages.some(
      (m) =>
        Array.isArray(m.content) &&
        m.content.some((b) => b && typeof b === "object" && (b as { type?: string }).type === "image"),
    );
    const prompt: string | AsyncIterable<unknown> = hasImage
      ? renderPromptWithImages(req)
      : renderPrompt(req);
    const abortController = req.signal ? abortFromSignal(req.signal) : undefined;

    const stream = query({
      prompt,
      options: {
        model: req.model,
        systemPrompt: req.system,
        includePartialMessages: true,
        // Single-turn — we want a reply, not an agent loop.
        maxTurns: 1,
        // Disable all built-in tools: this is a pure text completion, no
        // codebase editing or shell execution.
        tools: [],
        // Don't prompt the user; deny anything not pre-approved.
        permissionMode: "dontAsk",
        ...(abortController ? { abortController } : {}),
      },
    });

    let promptTokens = 0;
    let completionTokens = 0;
    let sawDelta = false;
    let assistantFallback = "";

    for await (const msg of stream) {
      // Streaming path: text_delta events yield deltas as they arrive.
      if (msg.type === "stream_event") {
        const ev = (msg as { event: { type: string; delta?: { type?: string; text?: string } } }).event;
        if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta" && typeof ev.delta.text === "string") {
          sawDelta = true;
          yield { type: "text", delta: ev.delta.text };
        }
        continue;
      }

      // Buffered fallback: complete assistant message. We only emit its text
      // if no streaming deltas arrived (so we don't double-yield in the
      // streaming path, where assistant + stream_event can both appear).
      if (msg.type === "assistant") {
        const m = msg as {
          message: { content: Array<{ type: string; text?: string }> };
        };
        for (const block of m.message.content) {
          if (block.type === "text" && typeof block.text === "string") {
            assistantFallback += block.text;
          }
        }
        continue;
      }

      // Terminal usage event.
      if (msg.type === "result") {
        const usage = (msg as { usage?: { input_tokens?: number; output_tokens?: number } }).usage;
        if (usage) {
          if (typeof usage.input_tokens === "number") promptTokens = usage.input_tokens;
          if (typeof usage.output_tokens === "number") completionTokens = usage.output_tokens;
        }
        // result is terminal — break out so we don't keep iterating.
        break;
      }

      // All other message types (system bootstrap, hooks, status, etc.) are
      // irrelevant for text-completion use; ignore them.
    }

    if (!sawDelta && assistantFallback.length > 0) {
      yield { type: "text", delta: assistantFallback };
    }

    yield { type: "done", promptTokens, completionTokens };
  }
}

/**
 * Image-bearing path: emit a single SDKUserMessage whose content combines all
 * the flattened few-shot text turns into one text block, followed by each
 * image block in order. Few-shot interleaving is already lost in the
 * string-prompt path (it just labels turns "User:"/"Assistant:" inside one
 * user input), so collapsing to one user message preserves the same model
 * input shape — just with images appended.
 */
function renderPromptWithImages(req: GenerateRequest): AsyncIterable<unknown> {
  const textBody = renderPrompt(req);
  const images: Array<{ type: "image"; source: { type: "base64"; media_type: string; data: string } }> = [];
  for (const m of req.messages) {
    if (!Array.isArray(m.content)) continue;
    for (const block of m.content) {
      if (block && typeof block === "object" && (block as { type?: string }).type === "image") {
        images.push(block as { type: "image"; source: { type: "base64"; media_type: string; data: string } });
      }
    }
  }
  const content: Array<unknown> = [{ type: "text", text: textBody }, ...images];
  const message = {
    type: "user" as const,
    message: { role: "user" as const, content },
    parent_tool_use_id: null,
  };
  return (async function* () {
    yield message;
  })();
}

function renderPrompt(req: GenerateRequest): string {
  // System prompt is delivered separately via options.systemPrompt; here we
  // just flatten the user/assistant turns into a single prompt string the
  // SDK can hand to the CLI. Each turn becomes one labeled paragraph so the
  // model can tell speakers apart.
  const parts: string[] = [];
  for (const m of req.messages) {
    const text = renderContent(m.content);
    if (!text) continue;
    parts.push(`${m.role === "assistant" ? "Assistant" : "User"}: ${text}`);
  }
  return parts.join("\n\n");
}

function renderContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const out: string[] = [];
    for (const block of content) {
      if (block && typeof block === "object" && (block as { type?: string }).type === "text") {
        const text = (block as { text?: unknown }).text;
        if (typeof text === "string") out.push(text);
      }
    }
    return out.join("");
  }
  return "";
}

function abortFromSignal(signal: AbortSignal): AbortController {
  // The SDK accepts an AbortController, not a bare signal. Bridge them.
  const ac = new AbortController();
  if (signal.aborted) {
    ac.abort(signal.reason);
  } else {
    signal.addEventListener("abort", () => ac.abort(signal.reason), { once: true });
  }
  return ac;
}
