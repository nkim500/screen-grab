import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import matter from "gray-matter";

export interface ExampleFrontmatter {
  context: string;
  audience: string;
  length: "short" | "medium" | "long";
}

export interface VoiceExample {
  relPath: string;          // e.g. "gmail-work/001.md"
  frontmatter: ExampleFrontmatter;
  body: string;
}

export interface Voice {
  style: string;
  about: string;
  examplesByBucket: Record<string, VoiceExample[]>;
}

async function walkMarkdown(root: string, relDir = ""): Promise<string[]> {
  const fullDir = path.join(root, relDir);
  const entries = await readdir(fullDir, { withFileTypes: true });
  const out: string[] = [];
  for (const e of entries) {
    const rel = path.join(relDir, e.name);
    if (e.isDirectory()) {
      out.push(...(await walkMarkdown(root, rel)));
    } else if (e.isFile() && e.name.endsWith(".md")) {
      out.push(rel);
    }
  }
  return out;
}

export async function loadVoice(voiceDir: string): Promise<Voice> {
  const style = await readFile(path.join(voiceDir, "style.md"), "utf-8");
  const about = await readFile(path.join(voiceDir, "about.md"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => {
      if (e.code === "ENOENT") return "";
      throw e;
    },
  );
  const examplesDir = path.join(voiceDir, "examples");
  const files = await walkMarkdown(examplesDir);

  const examplesByBucket: Record<string, VoiceExample[]> = {};
  for (const rel of files) {
    const bucket = rel.split(path.sep)[0]!;
    const raw = await readFile(path.join(examplesDir, rel), "utf-8");
    const parsed = matter(raw);
    const fm = parsed.data as ExampleFrontmatter;
    if (!examplesByBucket[bucket]) examplesByBucket[bucket] = [];
    examplesByBucket[bucket]!.push({
      relPath: rel,
      frontmatter: fm,
      body: parsed.content,
    });
  }

  return { style, about, examplesByBucket };
}
