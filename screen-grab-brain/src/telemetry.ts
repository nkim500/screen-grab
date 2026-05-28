import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";

export interface TelemetryRecord {
  reqId: string;
  ts: string;
  app: string;
  windowTitle: string;
  intent: "draft";
  context: { axTreeHash: string | null; screenshotHash: string | null };
  voice: { styleHash: string; exampleFiles: string[] };
  model: string;
  backend: "anthropic-api" | "claude-code-sdk";
  promptTokens: number;
  completionTokens: number;
  latencyMs: number;
  draft: string;
  outcome: "pending" | "accepted" | "edited" | "regenerated" | "dismissed" | "error";
  final: string | null;
  editDistance: number | null;
  durationFromGenToCloseMs: number | null;
  errorMessage?: string;
  /** Present iff this row originated from dictation. */
  spokenIntent: string | null;
  /** Present iff spokenIntent is set; identifies the STT backend used. */
  transcriberName: string | null;
}

export interface TelemetryResolution {
  reqId: string;
  ts: string;
  outcome: "accepted" | "edited" | "regenerated" | "dismissed" | "error";
  final: string | null;
  durationFromGenToCloseMs: number | null;
}

export class TelemetryLog {
  private chain: Promise<void> = Promise.resolve();
  private dirEnsured = false;

  constructor(private readonly filePath: string) {}

  append(record: TelemetryRecord): Promise<void> {
    this.chain = this.chain.then(() => this.write(record));
    return this.chain;
  }

  appendResolution(resolution: TelemetryResolution): Promise<void> {
    this.chain = this.chain.then(() => this.writeResolution(resolution));
    return this.chain;
  }

  private async write(record: TelemetryRecord): Promise<void> {
    try {
      if (!this.dirEnsured) {
        await mkdir(path.dirname(this.filePath), { recursive: true });
        this.dirEnsured = true;
      }
      const line = JSON.stringify(record) + "\n";
      await appendFile(this.filePath, line, "utf-8");
    } catch (err) {
      console.error("[telemetry] write failed:", err);
    }
  }

  private async writeResolution(resolution: TelemetryResolution): Promise<void> {
    try {
      if (!this.dirEnsured) {
        await mkdir(path.dirname(this.filePath), { recursive: true });
        this.dirEnsured = true;
      }
      const line = JSON.stringify(resolution) + "\n";
      await appendFile(this.filePath, line, "utf-8");
    } catch (err) {
      console.error("[telemetry] resolution write failed:", err);
    }
  }
}
