import { describe, it, expect } from "vitest";
import { loadConfig } from "../src/config.js";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VALID = path.join(__dirname, "fixtures/config-valid.json");
const INVALID = path.join(__dirname, "fixtures/config-invalid.json");

describe("loadConfig", () => {
  it("loads a valid config and applies defaults", async () => {
    const cfg = await loadConfig({ path: VALID, repoRoot: "/tmp/repo" });
    expect(cfg.backend).toBe("anthropic-api");
    expect(cfg.model).toBe("claude-opus-4-7");
    expect(cfg.maxTokens).toBe(600);          // default
    expect(cfg.timeoutMs).toBe(20000);        // default
    expect(cfg.persistRawContext).toBe(false); // default
  });

  it("expands ${repoRoot} in voiceDir and telemetryPath", async () => {
    const cfg = await loadConfig({ path: VALID, repoRoot: "/tmp/repo" });
    expect(cfg.voiceDir).toBe("/tmp/repo/voice");
    expect(cfg.telemetryPath).toBe("/tmp/repo/voice/telemetry.jsonl");
  });

  it("expands ~ in path fields", async () => {
    process.env.HOME = "/Users/test";
    const cfg = await loadConfig({
      path: VALID,
      repoRoot: "/tmp/repo",
      override: { voiceDir: "~/voice" },
    });
    expect(cfg.voiceDir).toBe("/Users/test/voice");
  });

  it("throws on an invalid backend value", async () => {
    await expect(loadConfig({ path: INVALID, repoRoot: "/tmp/repo" })).rejects.toThrow(
      /backend/,
    );
  });

  it("returns full defaults when given only required fields", async () => {
    const cfg = await loadConfig({
      path: VALID,
      repoRoot: "/tmp/repo",
    });
    expect(cfg.hotkey).toBe("RightCommand");
    expect(cfg.axTextThreshold).toBe(200);
    expect(cfg.logLevel).toBe("info");
  });
});
