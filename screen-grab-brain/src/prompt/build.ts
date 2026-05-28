import type { Voice, VoiceExample } from "../voice/index.js";

export interface AxNode {
  role: string;
  text: string;
}

export interface BrainRequest {
  reqId: string;
  app: string;
  windowTitle: string;
  intent: "draft";
  axTree: {
    focusedFieldRole: string;
    focusedFieldText: string;
    siblingTexts: AxNode[];
  };
  screenshotBase64?: string;
  /** Present iff this request originated from dictation. */
  spokenIntent?: string;
  /** Present iff `spokenIntent` is set; identifies the STT backend used. */
  transcriberName?: string;
}

export interface AnthropicTextBlock {
  type: "text";
  text: string;
}

export interface AnthropicImageBlock {
  type: "image";
  source: {
    type: "base64";
    media_type: "image/png" | "image/jpeg" | "image/gif" | "image/webp";
    data: string;
  };
}

export type AnthropicContentBlock = AnthropicTextBlock | AnthropicImageBlock;

export interface MessageParam {
  role: "user" | "assistant";
  content: AnthropicContentBlock[];
}

export interface PromptOutput {
  system: string;
  messages: MessageParam[];
}

const SYSTEM_PREAMBLE = `You are a writing assistant that drafts text in the user's exact voice.
Output is pasted verbatim into the focused field — no preamble, no
explanation, no meta-commentary, no markdown unless the destination supports it.
Match the tone, sentence length, vocabulary, and quirks shown in the user's
style guide and few-shot examples below.

Source hierarchy (apply in order):
1. Focused field text (if present) is the SEED — continue from where it ends.
2. Spoken intent (if present) is the DIRECTION — what to say next, or what to say if no seed.
3. Screen context and evidence about the user are REFERENCE only — match tone,
   register, and audience. Never lift content from them into the draft.

Style guide:
`;

function renderExampleAsUserTurn(ex: VoiceExample): string {
  return [
    `Example context: ${ex.frontmatter.context}`,
    `Audience: ${ex.frontmatter.audience}`,
    `Length: ${ex.frontmatter.length}`,
    "",
    "Draft a reply.",
  ].join("\n");
}

function renderRequestAsUserTurn(req: BrainRequest, hasEvidence: boolean): string {
  const sibs = req.axTree.siblingTexts.map((n) => `  - [${n.role}] ${n.text}`).join("\n");
  // When the AX read failed, the daemon falls back to a screenshot and sends
  // an empty axTree (role=AXUnknown, no siblings). Detect that shape so the
  // prompt tells the model to lean on the image, not the (absent) AX data.
  const usingScreenshotFallback =
    !!req.screenshotBase64 &&
    req.axTree.focusedFieldRole === "AXUnknown" &&
    req.axTree.siblingTexts.length === 0;

  // Four cells from the source hierarchy in the preamble:
  //   seed   direction      → continue the seed in the dictated direction
  //   seed   ∅              → continue the seed using screen as reference
  //   ∅      direction      → render the dictation as the draft (strict polish)
  //   ∅      ∅              → draft from screen context only
  const hasSeed = !!req.axTree.focusedFieldText;
  const hasDirection = !!req.spokenIntent;

  let closing: string;
  if (hasSeed && hasDirection) {
    closing = `Output ONLY the continuation that comes after the focused field text — do not repeat the focused field text itself, it is already in the field. Direction: ${req.spokenIntent}`;
  } else if (hasSeed) {
    closing = "Output ONLY the continuation that comes after the focused field text — do not repeat the focused field text itself, it is already in the field.";
  } else if (hasDirection) {
    // Strict polish: dictated intent is the entire message, only polish
    // punctuation/grammar/capitalization. Spelled out because the model
    // otherwise expands when the screen has obviously-relevant content.
    closing = `Render the spoken intent below as the entire draft — polish punctuation, capitalization, and grammar only. Do not expand or add follow-up. Direction: ${req.spokenIntent}`;
  } else {
    closing = "Draft for the focused field, in the user's voice.";
  }

  // Length hint from the focused field role. Single-line inputs (search
  // boxes, comboboxes, address fields) expect a few words; AXTextArea is
  // the only role where prose is appropriate by default.
  const role = req.axTree.focusedFieldRole;
  const isSingleLine =
    role === "AXTextField" ||
    role === "AXComboBox" ||
    role === "AXSearchField" ||
    role === "AXPopUpButton";
  if (isSingleLine) {
    closing = closing + "\nThis field is single-line — respond with a short phrase or a few words, no sentences.";
  }

  if (usingScreenshotFallback) {
    closing = [
      "The accessibility read failed for this app, so a screenshot of the focused window is attached below.",
      "Identify the focused field and the relevant visible context from the screenshot, then draft accordingly.",
      "",
      closing,
    ].join("\n");
  }

  return [
    `App: ${req.app}`,
    `Window: ${req.windowTitle}`,
    `Focused field role: ${req.axTree.focusedFieldRole}`,
    `Focused field current text: ${req.axTree.focusedFieldText || "(empty)"}`,
    "",
    "Visible context on screen:",
    sibs || (usingScreenshotFallback ? "  (see attached screenshot)" : "  (none)"),
    "",
    closing,
  ].join("\n");
}

export function buildPrompt(
  req: BrainRequest,
  voice: Voice,
  bucket: string,
): PromptOutput {
  const hasEvidence = voice.about.trim().length > 0;
  const system = hasEvidence
    ? SYSTEM_PREAMBLE + voice.style + "\n\nEvidence about the user:\n" + voice.about
    : SYSTEM_PREAMBLE + voice.style;

  const examples = voice.examplesByBucket[bucket] ?? voice.examplesByBucket["default"] ?? [];
  const messages: MessageParam[] = [];

  for (const ex of examples) {
    messages.push({
      role: "user",
      content: [{ type: "text", text: renderExampleAsUserTurn(ex) }],
    });
    messages.push({
      role: "assistant",
      content: [{ type: "text", text: ex.body.trim() }],
    });
  }

  const finalContent: AnthropicContentBlock[] = [
    { type: "text", text: renderRequestAsUserTurn(req, hasEvidence) },
  ];
  if (req.screenshotBase64) {
    finalContent.push({
      type: "image",
      source: { type: "base64", media_type: "image/png", data: req.screenshotBase64 },
    });
  }
  messages.push({ role: "user", content: finalContent });

  return { system, messages };
}
