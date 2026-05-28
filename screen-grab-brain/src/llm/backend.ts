import type { MessageParam } from "../prompt/index.js";

export interface GenerateRequest {
  system: string;
  messages: MessageParam[];
  model: string;
  maxTokens: number;
  signal?: AbortSignal;
}

export type GenerateChunk =
  | { type: "text"; delta: string }
  | { type: "done"; promptTokens: number; completionTokens: number };

export interface LLMBackend {
  readonly name: "anthropic-api" | "claude-code-sdk";
  generate(req: GenerateRequest): AsyncIterable<GenerateChunk>;
}
