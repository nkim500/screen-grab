import net from "node:net";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { generate } from "./generator.js";
import type { Config } from "./config.js";
import type { LLMBackend } from "./llm/backend.js";
import type { BrainRequest } from "./prompt/index.js";
import { TelemetryLog, type TelemetryResolution } from "./telemetry.js";
import { loadConfig } from "./config.js";
import { AnthropicAPIBackend } from "./llm/anthropic-api.js";
import { ClaudeCodeSDKBackend } from "./llm/claude-code-sdk.js";

export interface IPCServerHandle {
  close(): Promise<void>;
}

export interface StartIPCServerArgs {
  socketPath: string;
  cfg: Config;
  backend: LLMBackend;
}

export async function startIPCServer(args: StartIPCServerArgs): Promise<IPCServerHandle> {
  const { socketPath, cfg, backend } = args;

  // Stale socket cleanup. If a previous run crashed, the socket file may still exist.
  await fs.rm(socketPath, { force: true });
  await fs.mkdir(path.dirname(socketPath), { recursive: true });

  // One TelemetryLog per server: its internal chain serializes appends across
  // any number of concurrent connections. Constructing a fresh instance per
  // feedback call would race on the same file once we allow parallel requests.
  const telemetry = new TelemetryLog(cfg.telemetryPath);

  const connections = new Set<net.Socket>();

  const server = net.createServer((conn) => {
    connections.add(conn);
    conn.once("close", () => connections.delete(conn));
    handleConnection(conn, cfg, backend, telemetry).catch((err) => {
      console.error("[ipc] connection error:", err);
      conn.destroy();
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });

  return {
    close: () =>
      new Promise<void>((resolve) => {
        // Destroy in-flight connections so server.close()'s callback fires promptly.
        for (const conn of connections) conn.destroy();
        server.close(async (err) => {
          if (err) console.error("[ipc] server close error:", err);
          try {
            await fs.rm(socketPath, { force: true });
          } finally {
            resolve();
          }
        });
      }),
  };
}

async function handleConnection(
  conn: net.Socket,
  cfg: Config,
  backend: LLMBackend,
  telemetry: TelemetryLog,
): Promise<void> {
  let buf = "";
  let chain: Promise<void> = Promise.resolve();
  conn.setEncoding("utf-8");

  conn.on("data", (chunk: string) => {
    buf += chunk;
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: unknown;
      try {
        msg = JSON.parse(line);
      } catch {
        console.error("[ipc] malformed JSON, dropping:", line.slice(0, 200));
        continue;
      }
      // Append to chain so each dispatch runs only after the previous one
      // completes. Per spec §6 each connection serializes its requests.
      chain = chain
        .then(() => dispatch(conn, cfg, backend, telemetry, msg))
        .catch((err) => {
          console.error("[ipc] dispatch error:", err);
          conn.destroy();
        });
    }
  });

  conn.on("error", (err) => {
    console.error("[ipc] socket error:", err);
  });
}

async function dispatch(
  conn: net.Socket,
  cfg: Config,
  backend: LLMBackend,
  telemetry: TelemetryLog,
  msg: unknown,
): Promise<void> {
  if (typeof msg !== "object" || msg === null) return;
  const m = msg as { type?: string };
  if (m.type === "generate") {
    await runGenerate(conn, cfg, backend, m as unknown as BrainRequest);
    return;
  }
  if (m.type === "feedback") {
    await runFeedback(telemetry, m as FeedbackMessage);
    return;
  }
  console.error("[ipc] unknown message type:", m.type);
}

async function runGenerate(
  conn: net.Socket,
  cfg: Config,
  backend: LLMBackend,
  req: BrainRequest,
): Promise<void> {
  try {
    for await (const ev of generate(req, cfg, backend)) {
      writeJSON(conn, ev);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    writeJSON(conn, { type: "error", reqId: req.reqId, message });
  }
}

interface FeedbackMessage {
  type: "feedback";
  reqId: string;
  event: "accepted" | "edited" | "regenerated" | "dismissed" | "error";
  finalText?: string;
  durationFromGenToCloseMs?: number;
}

async function runFeedback(log: TelemetryLog, msg: FeedbackMessage): Promise<void> {
  const resolution: TelemetryResolution = {
    reqId: msg.reqId,
    ts: new Date().toISOString(),
    outcome: msg.event,
    final: msg.finalText ?? null,
    durationFromGenToCloseMs: msg.durationFromGenToCloseMs ?? null,
  };
  await log.appendResolution(resolution);
}

// NOTE: write() return value is intentionally not checked. Local Unix socket
// buffers are large enough for streaming deltas; backpressure handling can be
// added if/when this becomes a TCP socket.
function writeJSON(conn: net.Socket, obj: unknown): void {
  if (conn.destroyed || !conn.writable) return;
  conn.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv: string[]): { configPath: string; socketPath?: string } {
  const ci = argv.indexOf("--config");
  const si = argv.indexOf("--socket");
  const configPath =
    ci >= 0 && argv[ci + 1] ? argv[ci + 1]! : `${process.env.HOME}/.config/screen-grab/config.json`;
  const socketPath = si >= 0 && argv[si + 1] ? argv[si + 1]! : undefined;
  return { configPath, socketPath };
}

function pickBackend(cfg: Config): LLMBackend {
  switch (cfg.backend) {
    case "anthropic-api": {
      const apiKey = process.env.ANTHROPIC_API_KEY;
      if (!apiKey) throw new Error("ANTHROPIC_API_KEY not set");
      return new AnthropicAPIBackend({ apiKey, baseURL: cfg.baseURL });
    }
    case "claude-code-sdk":
      return new ClaudeCodeSDKBackend();
    default:
      throw new Error(`Unknown backend: ${cfg.backend}`);
  }
}

export async function main(): Promise<void> {
  const { configPath, socketPath: socketArg } = parseArgs(process.argv.slice(2));
  const repoRoot = process.env.REPO_ROOT ?? process.cwd();
  const cfg = await loadConfig({ path: configPath, repoRoot });
  const backend = pickBackend(cfg);
  const socketPath = socketArg ?? `${process.env.HOME}/.screen-grab.sock`;

  const handle = await startIPCServer({ socketPath, cfg, backend });
  console.error(`[ipc] listening on ${socketPath}`);
  // Single machine-readable readiness token; daemon parses this from stdout
  // to know it's safe to connect. Stderr stays for human logs.
  process.stdout.write("READY\n");

  // The server is long-lived. Wait for SIGTERM/SIGINT to shut down gracefully.
  const stop = async (): Promise<void> => {
    console.error("[ipc] shutting down");
    try {
      await handle.close();
    } catch (err) {
      console.error("[ipc] close error, forcing exit:", err);
    }
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

// Direct-invocation detection: only run main() when this file is the entry,
// not when it's imported by tests. Standard Node pattern using import.meta.url.
const isMainModule = (() => {
  try {
    return fileURLToPath(import.meta.url) === process.argv[1];
  } catch {
    return false;
  }
})();
if (isMainModule) {
  main().catch((err) => {
    console.error(`[ipc fatal] ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
