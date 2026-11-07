// herdr's saved SSH machines. A machine is found by its target (the
// instance name, the ssh Host alias): the label may be renamed in herdr.
import { CliError, type Ctx } from "./context.ts";

export interface Machine {
  readonly id: string;
  readonly label: string;
  readonly target: string;
  readonly enabled: boolean;
}

function isMachine(value: unknown): value is Machine {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return typeof v["id"] === "string" && typeof v["label"] === "string" && typeof v["target"] === "string";
}

/** herdr's machines; an unreadable list counts as none. */
export function listMachines(ctx: Ctx): Machine[] {
  const result = ctx.run("herdr", ["machine", "list", "--json"]);
  if (result.code !== 0) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.filter(isMachine).map((m) => ({
    id: m.id,
    label: m.label,
    target: m.target,
    enabled: (m as { enabled?: unknown }).enabled !== false,
  }));
}

export function machineFor(ctx: Ctx, target: string): Machine | undefined {
  return listMachines(ctx).find((m) => m.target === target);
}

/** Save <target> as a herdr machine shown as <label>. */
export function addMachine(ctx: Ctx, target: string, label: string): void {
  if (ctx.run("herdr", ["machine", "add", target, "--label", label], { output: "stderr" }).code !== 0) {
    throw new CliError(`herdr could not add machine ${target}`);
  }
}

/** herdr 0.9.5 takes the profile id first (its --help shows the other order,
 *  which it rejects). */
export function renameMachine(ctx: Ctx, id: string, label: string): void {
  if (ctx.run("herdr", ["machine", "rename", id, "--label", label], { output: "stderr" }).code !== 0) {
    throw new CliError(`herdr could not rename machine ${id}`);
  }
}

export function removeMachine(ctx: Ctx, id: string): void {
  if (ctx.run("herdr", ["machine", "remove", id], { output: "stderr" }).code !== 0) {
    throw new CliError(`could not remove herdr machine ${id}`);
  }
}

/** herdr reaches the machine through its own forwarding. */
export function forwardingWorks(ctx: Ctx, id: string): boolean {
  return ctx.run("herdr", ["--machine", id, "workspace", "list"]).code === 0;
}
