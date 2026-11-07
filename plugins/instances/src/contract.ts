// The herdr-worktree plugin contract (version 1): what core calls through
// bin/hw-plugin. stdout carries JSON (describe, machines) or the remote
// command's own output (exec); messages go to stderr.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CliError, type Ctx, PLUGIN_DIR } from "./context.ts";
import { listMachines, machineFor, removeMachine } from "./herdr.ts";
import { checkoutDir, ensureOne, planLabel, plannedLabel, resolve, syncLabel } from "./instances.ts";
import { findInstance, readManifest } from "./manifest.ts";
import { shellQuote } from "./proc.ts";
import { readUnregistered, writeUnregistered } from "./unregistered.ts";

export const CONTRACT_VERSION = 1;

export interface Description {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly contract: number;
  /** skill directories the orchestrator reads while this plugin is enabled */
  readonly skills: readonly string[];
  /** what core calls after `plugins.sh enable` and before `plugins.sh disable` */
  readonly hooks: readonly ("enable" | "disable")[];
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
    hooks: ["enable", "disable"],
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

/** What to do when disable could not take every machine out of herdr: core
 *  has unlinked the plugin by then, but its own bin still answers, and
 *  disable takes the rest out without starting anything. */
const AGAIN = "once herdr works, run: plugins/instances/bin/hw-plugin disable";

function isRunning(ctx: Ctx, name: string): boolean {
  const result = ctx.run("docker", ["ps", "-q", "--filter", `label=com.docker.compose.project=${name}`, "--filter", "status=running"]);
  return result.code === 0 && result.stdout.trim() !== "";
}

/** `plugins.sh disable`: take this plugin's machines out of herdr, so it
 *  shows none while the plugin is off (a label renamed in herdr is adopted
 *  first), and record them for enable. The manifest, containers and volumes
 *  stay; a container still running is named with the command that stops it.
 *  Returns false when a machine could not be removed. */
export function disable(ctx: Ctx): boolean {
  let manifest = readManifest(ctx);
  const listed = ctx.run("herdr", ["machine", "list", "--json"]);
  if (listed.code !== 0) {
    ctx.err(`Error: cannot read herdr's machines (${listed.stderr.trim() || "herdr failed"}); ${AGAIN}`);
    return false;
  }
  const removed = readUnregistered(ctx);
  let ok = true;
  for (const listedInstance of manifest.instances) {
    if (machineFor(ctx, listedInstance.name) === undefined) continue;
    manifest = syncLabel(ctx, manifest, listedInstance).manifest;
    const machine = machineFor(ctx, listedInstance.name);
    if (machine === undefined) continue;
    try {
      removeMachine(ctx, machine.id);
    } catch (error) {
      if (!(error instanceof CliError)) throw error;
      ctx.err(`Error: ${listedInstance.name}: ${error.message}; ${AGAIN}`);
      ok = false;
      continue;
    }
    removed.add(listedInstance.name);
    ctx.err(`${machine.label}: removed from herdr's machines`);
  }
  writeUnregistered(ctx, removed);
  for (const instance of manifest.instances) {
    if (instance.kind === "container" && isRunning(ctx, instance.name)) {
      ctx.err(`Note: ${instance.label} is still running; stop it with: docker compose -p ${instance.name} stop`);
    }
  }
  return ok;
}

/** `plugins.sh enable`: bring back (ensure: start, register) the machines
 *  disable took out of herdr. One that cannot come back is reported and kept
 *  for the next enable, and makes it return false; a name this manifest does
 *  not know (another checkout's) is kept as it is. */
export function enable(ctx: Ctx): boolean {
  const names = readUnregistered(ctx);
  if (names.size === 0) return true;
  const manifest = readManifest(ctx);
  const left = new Set<string>();
  for (const name of names) {
    // another checkout's manifest; `instance rm` forgets its own names
    if (findInstance(manifest, name) === undefined) {
      left.add(name);
      continue;
    }
    let done = false;
    try {
      done = ensureOne({ ...ctx, out: ctx.err }, name);
    } catch (error) {
      if (!(error instanceof CliError)) throw error;
      ctx.err(`Error: ${name}: ${error.message}`);
    }
    if (!done) left.add(name);
  }
  writeUnregistered(ctx, left);
  return [...left].every((name) => findInstance(manifest, name) === undefined);
}
