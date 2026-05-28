import Anthropic from "@anthropic-ai/sdk";
import type { GenerateRequest, GenerateChunk, LLMBackend } from "./backend.js";

export interface AnthropicAPIBackendOptions {
  apiKey: string;
  baseURL?: string;
}

export class AnthropicAPIBackend implements LLMBackend {
  readonly name = "anthropic-api" as const;
  private readonly client: Anthropic;

  constructor(opts: AnthropicAPIBackendOptions) {
    this.client = new Anthropic({ apiKey: opts.apiKey, baseURL: opts.baseURL });
  }

  async *generate(req: GenerateRequest): AsyncIterable<GenerateChunk> {
    const stream = this.client.messages.stream(
      {
        model: req.model,
        max_tokens: req.maxTokens,
        system: req.system,
        messages: req.messages.map((m) => ({
          role: m.role,
          content: m.content,
        })),
      },
      { signal: req.signal },
    );

    let promptTokens = 0;
    let completionTokens = 0;

    for await (const event of stream) {
      if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        yield { type: "text", delta: event.delta.text };
      } else if (event.type === "message_start") {
        promptTokens = event.message.usage.input_tokens;
      } else if (event.type === "message_delta") {
        completionTokens = event.usage.output_tokens;
      }
    }

    yield { type: "done", promptTokens, completionTokens };
  }
}
