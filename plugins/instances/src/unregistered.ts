// The instances `hw-plugin disable` took out of herdr, so `hw-plugin enable`
// brings back exactly those (ADR-0022). A JSON array of instance names in
// the plugin's config directory, shared by every checkout's manifest: a name
// another manifest does not know is kept for that manifest's enable.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Ctx } from "./context.ts";

export function readUnregistered(ctx: Ctx): Set<string> {
  try {
    const parsed: unknown = JSON.parse(readFileSync(ctx.paths.unregisteredFile, "utf8"));
    return new Set(Array.isArray(parsed) ? parsed.filter((n): n is string => typeof n === "string") : []);
  } catch {
    return new Set();
  }
}

export function writeUnregistered(ctx: Ctx, names: ReadonlySet<string>): void {
  mkdirSync(dirname(ctx.paths.unregisteredFile), { recursive: true });
  writeFileSync(ctx.paths.unregisteredFile, `${JSON.stringify([...names].sort())}\n`);
}

/** An instance removed with `instance rm` is not brought back by enable. */
export function forgetUnregistered(ctx: Ctx, name: string): void {
  const names = readUnregistered(ctx);
  if (names.delete(name)) writeUnregistered(ctx, names);
}
