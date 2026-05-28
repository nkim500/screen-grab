import { describe, it, expect } from "vitest";
import { loadVoice } from "../src/voice/index.js";
import { loadRouting, route } from "../src/voice/routing.js";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(__dirname, "fixtures/voice");

describe("loadVoice", () => {
  it("loads style.md", async () => {
    const v = await loadVoice(FIXTURE);
    expect(v.style).toContain("short, direct sentences");
  });

  it("loads about.md when present", async () => {
    const v = await loadVoice(FIXTURE);
    expect(v.about).toContain("AI infrastructure engineer");
    expect(v.about).toContain("Story bank");
  });

  it("returns empty about when about.md is absent", async () => {
    // about.md is optional — user may not have written one yet. ENOENT must
    // not break the daemon; loader returns "" and downstream gates on it.
    const dir = await mkdtemp(path.join(tmpdir(), "voice-no-about-"));
    await writeFile(path.join(dir, "style.md"), "style only");
    await mkdir(path.join(dir, "examples"));
    const v = await loadVoice(dir);
    expect(v.about).toBe("");
    expect(v.style).toBe("style only");
  });

  it("walks examples/ and groups by bucket", async () => {
    const v = await loadVoice(FIXTURE);
    expect(Object.keys(v.examplesByBucket).sort()).toEqual(["gmail-work", "linkedin"]);
    expect(v.examplesByBucket["gmail-work"]).toHaveLength(1);
    expect(v.examplesByBucket["linkedin"]).toHaveLength(1);
  });

  it("parses frontmatter on example files", async () => {
    const v = await loadVoice(FIXTURE);
    const ex = v.examplesByBucket["gmail-work"]![0]!;
    expect(ex.frontmatter.context).toMatch(/slipping deadline/);
    expect(ex.frontmatter.audience).toBe("internal teammate");
    expect(ex.frontmatter.length).toBe("short");
    expect(ex.body.trim()).toMatch(/^hey — yeah/);
    expect(ex.relPath).toBe("gmail-work/001.md");
  });
});

describe("voice routing", () => {
  it("routes Mail app to gmail-work bucket", async () => {
    const rules = await loadRouting(FIXTURE);
    expect(route(rules, { app: "Mail", windowTitle: "anything" })).toBe("gmail-work");
  });

  it("routes Chrome with linkedin.com in title to linkedin bucket", async () => {
    const rules = await loadRouting(FIXTURE);
    expect(
      route(rules, { app: "Google Chrome", windowTitle: "Some post | linkedin.com" }),
    ).toBe("linkedin");
  });

  it("falls back to 'default' when no rule matches", async () => {
    const rules = await loadRouting(FIXTURE);
    expect(route(rules, { app: "Slack", windowTitle: "" })).toBe("default");
  });
});
