import { createHash } from "node:crypto";
import { loadVoice, loadRouting, route } from "./voice/index.js";
import { buildPrompt, type BrainRequest } from "./prompt/index.js";
import { TelemetryLog, type TelemetryRecord } from "./telemetry.js";
import type { LLMBackend } from "./llm/backend.js";
import type { Config } from "./config.js";

export type BrainEvent =
  | { type: "delta"; reqId: string; text: string }
  | { type: "done"; reqId: string; promptTokens: number; completionTokens: number }
  | { type: "error"; reqId: string; message: string };

function sha256(s: string): string {
  return "sha256:" + createHash("sha256").update(s).digest("hex");
}

export async function* generate(
  req: BrainRequest,
  cfg: Config,
  backend: LLMBackend,
): AsyncIterable<BrainEvent> {
  const startedAt = Date.now();
  const telemetry = new TelemetryLog(cfg.telemetryPath);

  let voice;
  let bucket;
  try {
    voice = await loadVoice(cfg.voiceDir);
    const rules = await loadRouting(cfg.voiceDir);
    bucket = route(rules, { app: req.app, windowTitle: req.windowTitle });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    yield { type: "error", reqId: req.reqId, message };
    await telemetry.append(buildErrorRecord(req, cfg, "voice_load_failed: " + message));
    return;
  }

  const prompt = buildPrompt(req, voice, bucket);

  const exampleFiles = (voice.examplesByBucket[bucket] ?? []).map((e) => e.relPath);
  const styleHash = sha256(voice.style);

  let draft = "";
  let promptTokens = 0;
  let completionTokens = 0;

  try {
    for await (const chunk of backend.generate({
      system: prompt.system,
      messages: prompt.messages,
      model: cfg.model,
      maxTokens: cfg.maxTokens,
    })) {
      if (chunk.type === "text") {
        draft += chunk.delta;
        yield { type: "delta", reqId: req.reqId, text: chunk.delta };
      } else if (chunk.type === "done") {
        promptTokens = chunk.promptTokens;
        completionTokens = chunk.completionTokens;
      }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    yield { type: "error", reqId: req.reqId, message };
    await telemetry.append(buildErrorRecord(req, cfg, message));
    return;
  }

  const record: TelemetryRecord = {
    reqId: req.reqId,
    ts: new Date(startedAt).toISOString(),
    app: req.app,
    windowTitle: req.windowTitle,
    intent: req.intent,
    context: {
      axTreeHash: sha256(JSON.stringify(req.axTree)),
      screenshotHash: req.screenshotBase64 ? sha256(req.screenshotBase64) : null,
    },
    voice: { styleHash, exampleFiles },
    model: cfg.model,
    backend: backend.name,
    promptTokens,
    completionTokens,
    latencyMs: Date.now() - startedAt,
    draft,
    outcome: "pending",
    final: null,
    editDistance: null,
    durationFromGenToCloseMs: null,
    spokenIntent: req.spokenIntent ?? null,
    transcriberName: req.transcriberName ?? null,
  };

  try {
    yield { type: "done", reqId: req.reqId, promptTokens, completionTokens };
  } finally {
    await telemetry.append(record);
  }
}

function buildErrorRecord(req: BrainRequest, cfg: Config, message: string): TelemetryRecord {
  return {
    reqId: req.reqId,
    ts: new Date().toISOString(),
    app: req.app,
    windowTitle: req.windowTitle,
    intent: req.intent,
    context: { axTreeHash: null, screenshotHash: null },
    voice: { styleHash: "", exampleFiles: [] },
    model: cfg.model,
    backend: cfg.backend,
    promptTokens: 0,
    completionTokens: 0,
    latencyMs: 0,
    draft: "",
    outcome: "error",
    final: null,
    editDistance: null,
    durationFromGenToCloseMs: null,
    errorMessage: message,
    spokenIntent: req.spokenIntent ?? null,
    transcriberName: req.transcriberName ?? null,
  };
}
