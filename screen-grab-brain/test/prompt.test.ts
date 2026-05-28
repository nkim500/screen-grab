import { describe, it, expect } from "vitest";
import { buildPrompt, type BrainRequest } from "../src/prompt/index.js";
import type { Voice } from "../src/voice/index.js";

const voice: Voice = {
  style: "I write short, direct sentences. Lowercase-leaning.",
  about: "",
  examplesByBucket: {
    "gmail-work": [
      {
        relPath: "gmail-work/001.md",
        frontmatter: {
          context: "reply to a coworker about a slipping deadline",
          audience: "internal teammate",
          length: "short",
        },
        body: "hey — yeah, friday is tight. can we push to monday?",
      },
    ],
    default: [],
  },
};

const req: BrainRequest = {
  reqId: "r1",
  app: "Mail",
  windowTitle: "Reply: Q2 Roadmap",
  intent: "draft",
  axTree: {
    focusedFieldRole: "AXTextArea",
    focusedFieldText: "",
    siblingTexts: [
      { role: "AXStaticText", text: "From: Sarah" },
      { role: "AXStaticText", text: "Hey — quick question on the Q2 roadmap timing..." },
    ],
  },
};

describe("buildPrompt", () => {
  it("returns a system prompt that embeds the style guide", () => {
    const out = buildPrompt(req, voice, "gmail-work");
    expect(out.system).toContain("short, direct sentences");
  });

  it("includes few-shot example pairs from the matching bucket", () => {
    const out = buildPrompt(req, voice, "gmail-work");
    // First few messages should be the example pair
    const first = out.messages[0]!;
    expect(first.role).toBe("user");
    expect(JSON.stringify(first.content)).toContain("slipping deadline");
    const second = out.messages[1]!;
    expect(second.role).toBe("assistant");
    expect(JSON.stringify(second.content)).toContain("hey — yeah");
  });

  it("ends with a user message describing the screen state", () => {
    const out = buildPrompt(req, voice, "gmail-work");
    const last = out.messages[out.messages.length - 1]!;
    expect(last.role).toBe("user");
    const text = JSON.stringify(last.content);
    expect(text).toContain("Reply: Q2 Roadmap");
    expect(text).toContain("Hey — quick question");
  });

  it("falls back to default bucket when matching bucket is empty", () => {
    const out = buildPrompt(req, voice, "nonexistent");
    // Should still have a final user message even with no few-shots
    expect(out.messages.length).toBeGreaterThanOrEqual(1);
    expect(out.messages[out.messages.length - 1]!.role).toBe("user");
  });

  it("matches snapshot for a stable input", () => {
    const out = buildPrompt(req, voice, "gmail-work");
    expect(out).toMatchSnapshot();
  });
});

describe("buildPrompt — screenshot fallback", () => {
  // Empty axTree + non-null screenshotBase64 = daemon's fallback shape after
  // AX read failed (Chrome/Electron/Gmail compose).
  const fallbackReq: BrainRequest = {
    reqId: "rfb",
    app: "Google Chrome",
    windowTitle: "Inbox - Gmail",
    intent: "draft",
    axTree: {
      focusedFieldRole: "AXUnknown",
      focusedFieldText: "",
      siblingTexts: [],
    },
    screenshotBase64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=",
  };

  it("appends an image block to the final user message when screenshotBase64 is set", () => {
    const out = buildPrompt(fallbackReq, voice, "default");
    const lastUser = out.messages[out.messages.length - 1]!;
    expect(lastUser.role).toBe("user");
    const blocks = lastUser.content;
    expect(blocks.some((b) => b.type === "text")).toBe(true);
    const img = blocks.find((b) => b.type === "image");
    expect(img).toBeDefined();
    expect((img as { source: { data: string } }).source.data).toBe(fallbackReq.screenshotBase64);
  });

  it("uses screenshot-fallback closing when axTree is empty and screenshot is present", () => {
    const out = buildPrompt(fallbackReq, voice, "default");
    const lastUser = out.messages[out.messages.length - 1]!;
    const text = JSON.stringify(lastUser.content);
    expect(text).toContain("accessibility read failed");
    expect(text).toContain("see attached screenshot");
  });

  it("does not emit an image block when screenshotBase64 is absent (regression guard)", () => {
    const req = { ...fallbackReq, screenshotBase64: undefined };
    const out = buildPrompt(req, voice, "default");
    const lastUser = out.messages[out.messages.length - 1]!;
    expect(lastUser.content.some((b) => b.type === "image")).toBe(false);
  });
});

describe("buildPrompt — evidence layer (voice.about)", () => {
  const voiceWithAbout: Voice = {
    style: "I write short, direct sentences. Lowercase-leaning.",
    about: "Background: shipped feature X in 2 weeks, reduced latency 40%.",
    examplesByBucket: { default: [] },
  };

  it("appends evidence section to system prompt when voice.about is non-empty", () => {
    const out = buildPrompt(req, voiceWithAbout, "default");
    expect(out.system).toContain("Evidence about the user:");
    expect(out.system).toContain("shipped feature X");
  });

  it("omits evidence section when voice.about is empty", () => {
    const out = buildPrompt(req, voice, "default");
    expect(out.system).not.toContain("Evidence about the user:");
  });

  it("keeps the dictation closing when spokenIntent is set, even with evidence", () => {
    // Evidence belongs in the system prompt; dictation closings carry their
    // own polish-strict semantics that shouldn't be clobbered.
    const dictReq = { ...req, spokenIntent: "tell sarah friday at 3" };
    const out = buildPrompt(dictReq, voiceWithAbout, "default");
    const lastUser = out.messages[out.messages.length - 1]!;
    const text = JSON.stringify(lastUser.content);
    expect(text).toContain("Render the spoken intent below as the entire draft");
  });
});

describe("buildPrompt — source hierarchy in system preamble", () => {
  // The seed/direction/reference principle lives in SYSTEM_PREAMBLE so every
  // closing inherits it. Closings get to stay one line each.
  it("system prompt declares the source hierarchy", () => {
    const out = buildPrompt(req, voice, "default");
    expect(out.system).toContain("Source hierarchy");
    expect(out.system).toContain("SEED");
    expect(out.system).toContain("DIRECTION");
    expect(out.system).toContain("REFERENCE");
  });

  it("system prompt forbids meta-commentary and lifting reference content", () => {
    // Replaces the per-closing 'no questions to user' / 'no want-me-to phrasing'
    // guards that used to live in renderRequestAsUserTurn.
    const out = buildPrompt(req, voice, "default");
    expect(out.system).toContain("no meta-commentary");
    expect(out.system).toContain("Never lift content");
  });
});

describe("buildPrompt — field-shape length hint", () => {
  const baseReq: BrainRequest = {
    reqId: "r1",
    app: "GitHub",
    windowTitle: "screen-grab",
    intent: "draft",
    axTree: {
      focusedFieldRole: "AXTextField",
      focusedFieldText: "",
      siblingTexts: [],
    },
  };

  it("emits a single-line length hint for AXTextField", () => {
    const out = buildPrompt(baseReq, voice, "default");
    const lastUser = out.messages[out.messages.length - 1]!;
    expect(JSON.stringify(lastUser.content)).toContain("single-line");
  });

  it("emits single-line hint for AXComboBox / AXSearchField", () => {
    for (const role of ["AXComboBox", "AXSearchField", "AXPopUpButton"]) {
      const r = { ...baseReq, axTree: { ...baseReq.axTree, focusedFieldRole: role } };
      const out = buildPrompt(r, voice, "default");
      expect(JSON.stringify(out.messages[out.messages.length - 1]!.content)).toContain("single-line");
    }
  });

  it("does not emit the single-line hint for AXTextArea", () => {
    const r = { ...baseReq, axTree: { ...baseReq.axTree, focusedFieldRole: "AXTextArea" } };
    const out = buildPrompt(r, voice, "default");
    expect(JSON.stringify(out.messages[out.messages.length - 1]!.content)).not.toContain("single-line");
  });
});

describe("buildPrompt — dictation branches", () => {
  const baseReq: BrainRequest = {
    reqId: "r1",
    app: "Mail",
    windowTitle: "Reply: Q2 Roadmap",
    intent: "draft",
    axTree: {
      focusedFieldRole: "AXTextArea",
      focusedFieldText: "",
      siblingTexts: [{ role: "AXStaticText", text: "From: Sarah" }],
    },
  };

  it("uses the strict-polish closing when spokenIntent is present and field is empty (Dictate, empty seed)", () => {
    const req = { ...baseReq, spokenIntent: "tell sarah I'll get back to her by friday" };
    const out = buildPrompt(req, voice, "gmail-work");
    const text = JSON.stringify(out.messages[out.messages.length - 1]!.content);
    expect(text).toContain("Render the spoken intent below as the entire draft");
    expect(text).toContain("polish punctuation");
    expect(text).toContain("tell sarah I'll get back to her by friday");
  });

  it("uses continuation closing when both spokenIntent and focusedFieldText are present (Dictate + seed)", () => {
    const req = {
      ...baseReq,
      axTree: { ...baseReq.axTree, focusedFieldText: "Hi Sarah — thanks for the heads up." },
      spokenIntent: "I can do friday at 3, lemme know if that works",
    };
    const out = buildPrompt(req, voice, "gmail-work");
    const text = JSON.stringify(out.messages[out.messages.length - 1]!.content);
    expect(text).toContain("Output ONLY the continuation");
    expect(text).toContain("I can do friday at 3");
  });

  it("uses continuation closing when only focusedFieldText is present (Compose + seed)", () => {
    // New symmetry: cold-gen / Compose with existing field text continues
    // from that text, mirroring the dictation-with-seed branch.
    const req = {
      ...baseReq,
      axTree: { ...baseReq.axTree, focusedFieldText: "Hello my name is Nick and I want to" },
    };
    const out = buildPrompt(req, voice, "default");
    const text = JSON.stringify(out.messages[out.messages.length - 1]!.content);
    expect(text).toContain("Output ONLY the continuation");
    expect(text).not.toContain("Direction:");
  });

  it("uses the generic compose closing when neither spokenIntent nor focusedFieldText is present", () => {
    const out = buildPrompt(baseReq, voice, "gmail-work");
    const text = JSON.stringify(out.messages[out.messages.length - 1]!.content);
    expect(text).toContain("Draft for the focused field");
    expect(text).not.toContain("Output ONLY the continuation");
  });

  it("instructs the model not to repeat the seed text (anti-duplication regression guard)", () => {
    // Bug: model output 'Hello my name is Nick and I want to build something
    // crazyHello my name is Nick…' — full seed prefix lifted verbatim into
    // the continuation. Daemon also strips an exact prefix as defense in
    // depth (screen-grab-mac/Sources/App/main.swift handleAction).
    const r = {
      ...baseReq,
      axTree: { ...baseReq.axTree, focusedFieldText: "Hello my name is Nick" },
      spokenIntent: "build something crazy",
    };
    const out = buildPrompt(r, voice, "default");
    const text = JSON.stringify(out.messages[out.messages.length - 1]!.content);
    expect(text).toContain("do not repeat the focused field text");
  });
});
