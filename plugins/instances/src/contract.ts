// The herdr-worktree plugin contract (version 1): what core calls through
// bin/hw-plugin. stdout carries JSON (describe, machines) or the remote
// command's own output (exec); messages go to stderr.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CliError, type Ctx, PLUGIN_DIR } from "./context.ts";
import { listMachines } from "./herdr.ts";
import { checkoutDir, ensureOne, planLabel, plannedLabel, resolve } from "./instances.ts";
import { readManifest } from "./manifest.ts";
import { shellQuote } from "./proc.ts";

export const CONTRACT_VERSION = 1;

export interface Description {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly contract: number;
  /** skill directories the orchestrator reads while this plugin is enabled */
  readonly skills: readonly string[];
}

export interface MachineEntry {
  /** what herdr shows; the <label>/<pane> prefix and `herdr --machine` value */
  readonly label: string;
  /** the ssh Host alias (the instance name) */
  readonly target: string;
  /** the herdr-worktree checkout on that machine */
  readonly dir: string;
  /** saved as a herdr machine, so `herdr --machine <label>` works */
  readonly registered: boolean;
}

export function describe(): Description {
  const pkg = JSON.parse(readFileSync(join(PLUGIN_DIR, "package.json"), "utf8")) as { version?: unknown };
  return {
    id: "instances",
    name: "Instances: dev containers and remote hosts",
    version: typeof pkg.version === "string" ? pkg.version : "0.0.0",
    contract: CONTRACT_VERSION,
    skills: [join(PLUGIN_DIR, "skills", "instances"), join(PLUGIN_DIR, "skills", "instance-from-repo")],
  };
}

/** The machines with the label they will have once synced (ensure syncs
 *  it): a herdr label that is put back is never reported. Starts and renames
 *  nothing. */
export function machines(ctx: Ctx): MachineEntry[] {
  const saved = listMachines(ctx);
  const manifest = readManifest(ctx);
  return manifest.instances.map((instance) => {
    const machine = saved.find((m) => m.target === instance.name);
    return {
      label: machine === undefined ? instance.label : plannedLabel(planLabel(ctx, manifest, instance, machine), instance, machine),
      target: instance.name,
      dir: checkoutDir(instance),
      registered: machine !== undefined,
    };
  });
}

/** Bring <name-or-label> into use; its messages go to stderr. */
export function ensure(ctx: Ctx, arg: string): boolean {
  const instance = resolve(ctx, readManifest(ctx), arg);
  return ensureOne({ ...ctx, out: ctx.err }, instance.name);
}

/** Run <command> in the machine's checkout, as from a pane there
 *  (HERDR_ENV=1); output passes through and the exit status is returned. */
export function exec(ctx: Ctx, arg: string, command: readonly string[]): number {
  if (command.length === 0) throw new CliError("exec needs a command after --");
  const instance = resolve(ctx, readManifest(ctx), arg);
  // the checkout dir is validated and expanded remotely (~), so it stays unquoted
  const remote = `cd ${checkoutDir(instance)} && HERDR_ENV=1 ${command.map(shellQuote).join(" ")}`;
  return ctx.run("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", instance.name, remote], { output: "inherit" }).code;
}
