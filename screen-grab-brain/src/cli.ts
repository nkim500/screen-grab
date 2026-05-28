import { loadConfig } from "./config.js";
import type { Config } from "./config.js";
import { generate } from "./generator.js";
import { AnthropicAPIBackend } from "./llm/anthropic-api.js";
import type { LLMBackend } from "./llm/backend.js";
import type { BrainRequest } from "./prompt/index.js";

async function readStdin(): Promise<string> {
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  return data;
}

function parseArgs(argv: string[]): { configPath: string } {
  const i = argv.indexOf("--config");
  const configPath =
    i >= 0 && argv[i + 1] ? argv[i + 1]! : `${process.env.HOME}/.config/screen-grab/config.json`;
  return { configPath };
}

function pickBackend(cfg: Config): LLMBackend {
  switch (cfg.backend) {
    case "anthropic-api": {
      const apiKey = process.env.ANTHROPIC_API_KEY;
      if (!apiKey) {
        throw new Error("ANTHROPIC_API_KEY not set");
      }
      return new AnthropicAPIBackend({ apiKey, baseURL: cfg.baseURL });
    }
    case "claude-code-sdk":
      throw new Error("claude-code-sdk backend lands in Plan 3");
    default:
      throw new Error(`Unknown backend: ${cfg.backend}`);
  }
}

async function main(): Promise<void> {
  const { configPath } = parseArgs(process.argv.slice(2));
  const repoRoot = process.env.REPO_ROOT ?? process.cwd();
  const cfg = await loadConfig({ path: configPath, repoRoot });

  const stdin = await readStdin();
  const req = JSON.parse(stdin) as BrainRequest;

  const backend = pickBackend(cfg);

  for await (const ev of generate(req, cfg, backend)) {
    if (ev.type === "delta") {
      process.stdout.write(ev.text);
    } else if (ev.type === "done") {
      process.stdout.write("\n");
      process.stderr.write(
        `[done] reqId=${ev.reqId} promptTokens=${ev.promptTokens} completionTokens=${ev.completionTokens}\n`,
      );
    } else if (ev.type === "error") {
      process.stderr.write(`[error] reqId=${ev.reqId} ${ev.message}\n`);
      process.exit(1);
    }
  }
}

main().catch((err) => {
  process.stderr.write(`[fatal] ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
