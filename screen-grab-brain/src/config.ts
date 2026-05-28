import { z } from "zod";
import { readFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const ConfigSchema = z.object({
  backend: z.enum(["anthropic-api", "claude-code-sdk"]).default("anthropic-api"),
  model: z.string().default("claude-opus-4-7"),
  baseURL: z.string().optional(),
  hotkey: z.string().default("RightCommand"),
  maxTokens: z.number().int().positive().default(600),
  timeoutMs: z.number().int().positive().default(20000),
  voiceDir: z.string().default("${repoRoot}/voice"),
  telemetryPath: z.string().default("${repoRoot}/voice/telemetry.jsonl"),
  persistRawContext: z.boolean().default(false),
  axTextThreshold: z.number().int().nonnegative().default(200),
  logLevel: z.enum(["error", "warn", "info", "debug"]).default("info"),
});

export type Config = z.infer<typeof ConfigSchema>;

export interface LoadConfigOptions {
  path: string;
  repoRoot: string;
  /** Optional partial override merged on top of the file contents (used in tests). */
  override?: Partial<Config>;
}

function expandPaths(cfg: Config, repoRoot: string): Config {
  const expand = (s: string): string => {
    let out = s.replaceAll("${repoRoot}", repoRoot);
    if (out.startsWith("~")) out = path.join(os.homedir(), out.slice(1));
    return out;
  };
  return {
    ...cfg,
    voiceDir: expand(cfg.voiceDir),
    telemetryPath: expand(cfg.telemetryPath),
  };
}

export async function loadConfig(opts: LoadConfigOptions): Promise<Config> {
  const raw = await readFile(opts.path, "utf-8");
  const parsed = JSON.parse(raw);
  const merged = { ...parsed, ...opts.override };
  const validated = ConfigSchema.parse(merged);
  return expandPaths(validated, opts.repoRoot);
}
