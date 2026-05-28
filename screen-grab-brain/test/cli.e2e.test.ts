import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");
const BRAIN_ROOT = path.resolve(__dirname, "..");

let streamFixture: string;
let httpServer: http.Server;
let baseURL: string;

beforeAll(async () => {
  streamFixture = await readFile(
    path.join(__dirname, "fixtures/anthropic-stream.txt"),
    "utf-8",
  );
  httpServer = http.createServer((req, res) => {
    if (req.method === "POST" && req.url === "/v1/messages") {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.end(streamFixture);
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", () => resolve()));
  const port = (httpServer.address() as AddressInfo).port;
  baseURL = `http://127.0.0.1:${port}`;
});

afterAll(async () => {
  await new Promise<void>((resolve, reject) =>
    httpServer.close((err) => (err ? reject(err) : resolve())),
  );
});

let tmp: string;
let voiceDir: string;
let configPath: string;
let telemetryPath: string;

beforeEach(async () => {
  tmp = await mkdtemp(path.join(os.tmpdir(), "cli-"));
  voiceDir = path.join(tmp, "voice");
  telemetryPath = path.join(voiceDir, "telemetry.jsonl");
  await mkdir(path.join(voiceDir, "examples/gmail-work"), { recursive: true });
  await writeFile(path.join(voiceDir, "style.md"), "I write short.");
  await writeFile(
    path.join(voiceDir, "examples/gmail-work/001.md"),
    "---\ncontext: 'reply'\naudience: 'peer'\nlength: 'short'\n---\nhey.",
  );
  await writeFile(
    path.join(voiceDir, "routing.json"),
    JSON.stringify([{ match: { app: "Mail" }, bucket: "gmail-work" }]),
  );

  configPath = path.join(tmp, "config.json");
  await writeFile(
    configPath,
    JSON.stringify({
      backend: "anthropic-api",
      model: "claude-opus-4-7",
      voiceDir,
      telemetryPath,
      baseURL,
    }),
  );
});

describe("CLI e2e", () => {
  it("streams generated text to stdout and writes telemetry", async () => {
    const fixturePath = path.join(__dirname, "fixtures/context-gmail.json");
    const fixture = await readFile(fixturePath, "utf-8");

    const child = spawn(
      process.execPath,
      ["--import", "tsx", path.join(BRAIN_ROOT, "src/cli.ts"), "--config", configPath],
      {
        env: { ...process.env, ANTHROPIC_API_KEY: "test", REPO_ROOT },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    child.stdin.write(fixture);
    child.stdin.end();

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (b) => (stdout += b.toString()));
    child.stderr.on("data", (b) => (stderr += b.toString()));

    const code: number = await new Promise((resolve) => child.on("exit", resolve));
    expect(code, `stderr: ${stderr}`).toBe(0);

    // Streamed text appears in stdout
    expect(stdout).toContain("hey ");
    expect(stdout).toContain("sarah, ");
    expect(stdout).toContain("thanks for the note.");

    const tlm = await readFile(telemetryPath, "utf-8");
    const record = JSON.parse(tlm.trim());
    expect(record.reqId).toBe("test-r1");
    expect(record.draft).toContain("thanks for the note");
  }, 15000);
});
