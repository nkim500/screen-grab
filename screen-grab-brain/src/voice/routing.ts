import { readFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

const RuleSchema = z.object({
  match: z.object({
    app: z.string().optional(),
    windowTitleContains: z.string().optional(),
  }),
  bucket: z.string(),
});

export const RoutingSchema = z.array(RuleSchema);
export type RoutingRule = z.infer<typeof RuleSchema>;
export type RoutingRules = RoutingRule[];

export async function loadRouting(voiceDir: string): Promise<RoutingRules> {
  const raw = await readFile(path.join(voiceDir, "routing.json"), "utf-8");
  return RoutingSchema.parse(JSON.parse(raw));
}

export interface RouteContext {
  app: string;
  windowTitle: string;
}

export function route(rules: RoutingRules, ctx: RouteContext): string {
  for (const rule of rules) {
    const { app, windowTitleContains } = rule.match;
    if (app && app !== ctx.app) continue;
    if (windowTitleContains && !ctx.windowTitle.includes(windowTitleContains)) continue;
    return rule.bucket;
  }
  return "default";
}
