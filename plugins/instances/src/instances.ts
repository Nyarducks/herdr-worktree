// The instance operations: the manifest is the source of truth; containers
// are built and started here, remote hosts are only explained.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname } from "node:path";
import { CliError, CLI, type Ctx } from "./context.ts";
import * as container from "./container.ts";
import { addMachine, forwardingWorks, listMachines, type Machine, machineFor, removeMachine, renameMachine } from "./herdr.ts";
import {
  DEFAULT_CONTAINER_PORT,
  DEFAULT_DIR,
  DEFAULT_IMAGE,
  DEFAULT_REMOTE_PORT,
  findInstance,
  type Instance,
  type Manifest,
  readManifest,
  replaceInstance,
  withoutInstance,
  writeManifest,
} from "./manifest.ts";
import { guidance, remoteAddress, removeRemoteSshConfig, writeRemoteSshConfig } from "./remote.ts";
import { ensureInclude, probe, type Probe, probeWord } from "./ssh.ts";
import { dirProblem, hostProblem, identityProblem, labelProblem, nameProblem, portProblem, userProblem } from "./validate.ts";

/** The herdr-worktree checkout inside a container. */
const CONTAINER_DIR = "~/herdr-worktree";

export function checkoutDir(instance: Instance): string {
  return instance.kind === "container" ? CONTAINER_DIR : instance.dir;
}

export function address(instance: Instance): string {
  return instance.kind === "container" ? `127.0.0.1:${instance.port}` : remoteAddress(instance);
}

function fail(problem: string | undefined): void {
  if (problem !== undefined) throw new CliError(problem);
}

// --- names and labels ---------------------------------------------------------------

/** The instance behind a name, a herdr label or a manifest label. */
export function resolve(ctx: Ctx, manifest: Manifest, arg: string): Instance {
  const byName = findInstance(manifest, arg);
  if (byName !== undefined) return byName;
  const target = listMachines(ctx).find((m) => m.label === arg)?.target;
  const byHerdr = target === undefined ? undefined : findInstance(manifest, target);
  if (byHerdr !== undefined) return byHerdr;
  const byLabel = manifest.instances.find((i) => i.label === arg);
  if (byLabel !== undefined) return byLabel;
  throw new CliError(`no instance named or labeled '${arg}' (see: ${CLI} ls)`);
}

/** A label must be unique among herdr's machines and the manifest, ignoring case. */
export function checkLabel(ctx: Ctx, manifest: Manifest, label: string, name: string): void {
  fail(labelProblem(label));
  const lower = label.toLowerCase();
  const machine = listMachines(ctx).find((m) => m.label.toLowerCase() === lower && m.target !== name);
  if (machine !== undefined) throw new CliError(`label '${label}' is already used by herdr machine ${machine.target}`);
  const other = manifest.instances.find((i) => i.label.toLowerCase() === lower && i.name !== name);
  if (other !== undefined) throw new CliError(`label '${label}' is already used by instance ${other.name}`);
}

/** The label of each instance when the manifest and herdr last agreed: it
 *  tells which side changed since. An unreadable file counts as empty. */
function readAgreed(ctx: Ctx): Record<string, string> {
  try {
    const parsed: unknown = JSON.parse(readFileSync(ctx.paths.labelsFile, "utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return {};
    return Object.fromEntries(Object.entries(parsed).filter((e): e is [string, string] => typeof e[1] === "string"));
  } catch {
    return {};
  }
}

/** Record <label> as agreed for <name>; undefined forgets it. */
function recordAgreed(ctx: Ctx, name: string, label: string | undefined): void {
  const agreed = readAgreed(ctx);
  if (agreed[name] === label) return;
  if (label === undefined) delete agreed[name];
  else agreed[name] = label;
  mkdirSync(dirname(ctx.paths.labelsFile), { recursive: true });
  writeFileSync(ctx.paths.labelsFile, `${JSON.stringify(agreed, null, 2)}\n`);
}

/** What syncing an instance's label with herdr's machine would do. The side
 *  that changed since they last agreed wins: a label edited in the manifest
 *  renames herdr's machine ("push"), one renamed in herdr is copied into the
 *  manifest ("adopt"). With no record, or when both changed, the manifest
 *  wins. A herdr label the manifest cannot hold (invalid, or another
 *  instance's label) would make the manifest unreadable, so the manifest's
 *  label is put back on herdr ("putBack"); a manifest label herdr cannot take
 *  is reported and herdr keeps its own ("keep"). Reads only. */
export type LabelPlan =
  | { readonly kind: "same" }
  | { readonly kind: "adopt" }
  | { readonly kind: "putBack"; readonly reason: string }
  | { readonly kind: "push" }
  | { readonly kind: "keep"; readonly reason: string };

export function planLabel(ctx: Ctx, manifest: Manifest, instance: Instance, machine: Machine): LabelPlan {
  if (machine.label === instance.label) return { kind: "same" };
  const agreed = readAgreed(ctx)[instance.name];
  const herdrChanged = agreed !== undefined && instance.label === agreed;
  try {
    checkLabel(ctx, manifest, herdrChanged ? machine.label : instance.label, instance.name);
  } catch (error) {
    if (!(error instanceof CliError)) throw error;
    return herdrChanged ? { kind: "putBack", reason: error.message } : { kind: "keep", reason: error.message };
  }
  return herdrChanged ? { kind: "adopt" } : { kind: "push" };
}

/** The label herdr and the manifest share once the plan is carried out. */
export function plannedLabel(plan: LabelPlan, instance: Instance, machine: Machine): string {
  return plan.kind === "adopt" || plan.kind === "keep" ? machine.label : instance.label;
}

/** Bring the manifest's label and herdr's together (see planLabel); returns
 *  the (possibly updated) manifest, and whether herdr refused a rename — then
 *  herdr's label is not what planLabel promised. A refusal is reported, not
 *  thrown, so one machine cannot stop a listing. */
function syncLabel(ctx: Ctx, manifest: Manifest, instance: Instance): { manifest: Manifest; refused: boolean } {
  const machine = machineFor(ctx, instance.name);
  if (machine === undefined) return { manifest, refused: false };
  const plan = planLabel(ctx, manifest, instance, machine);
  const rename = (label: string): boolean => {
    try {
      renameMachine(ctx, machine.id, label);
      return true;
    } catch (error) {
      if (!(error instanceof CliError)) throw error;
      ctx.err(`Warning: ${instance.name}: ${error.message} to ${label}; herdr keeps ${machine.label}`);
      return false;
    }
  };
  switch (plan.kind) {
    case "same":
      recordAgreed(ctx, instance.name, instance.label);
      return { manifest, refused: false };
    case "adopt": {
      const next = replaceInstance(manifest, { ...instance, label: machine.label });
      writeManifest(ctx, next);
      recordAgreed(ctx, instance.name, machine.label);
      ctx.err(`${instance.name}: label ${instance.label} -> ${machine.label} (renamed in herdr; manifest updated)`);
      return { manifest: next, refused: false };
    }
    case "putBack":
      if (!rename(instance.label)) return { manifest, refused: true };
      ctx.err(`Warning: ${instance.name}: herdr's label '${machine.label}' cannot be used (${plan.reason}); renamed it back to ${instance.label}`);
      return { manifest, refused: false };
    case "keep":
      ctx.err(`Warning: ${instance.name}: the manifest's label cannot be applied to herdr (${plan.reason}); herdr keeps ${machine.label}`);
      return { manifest, refused: false };
    case "push":
      if (!rename(instance.label)) return { manifest, refused: true };
      recordAgreed(ctx, instance.name, instance.label);
      ctx.err(`${instance.name}: label ${machine.label} -> ${instance.label} (edited in the manifest; herdr renamed)`);
      return { manifest, refused: false };
  }
}

// --- ensure ----------------------------------------------------------------------------

/** Put an Include into ~/.ssh/config; a file that cannot take it (a
 *  read-only home-manager link, the line in a form or file we do not read)
 *  is a warning with the line to add, and the probe that follows tells
 *  whether ssh reaches the instance anyway. */
function includeOrWarn(ctx: Ctx, name: string, write: () => void): boolean {
  try {
    write();
    return true;
  } catch (error) {
    if (!(error instanceof CliError)) throw error;
    ctx.err(`Warning: ${name}: ${error.message}`);
    return false;
  }
}

/** The advice when the Include could not be put in place and ssh does not
 *  know <name>: with no Host entry it looks the alias itself up, so its
 *  error names <name> (with an entry it names the HostName — a DNS problem
 *  the usual advice covers). Neither a rebuild nor starting the host helps.
 *  Undefined for any other probe result — the Include may well be there in
 *  a form or file the plugin does not read. */
function includeAdvice(name: string, included: boolean, result: Probe): string | undefined {
  if (included || result.status !== "unreachable" || !result.error.includes(`Could not resolve hostname ${name}:`)) return undefined;
  return `Error: ${name}: ssh does not know it without the Include line above (${result.error}); add that line at the top of your ssh config, then run: ${CLI} ensure ${name}`;
}

function registerRemote(ctx: Ctx, name: string, label: string): void {
  let machine = machineFor(ctx, name);
  if (machine === undefined) {
    addMachine(ctx, name, label);
    machine = machineFor(ctx, name);
  }
  if (machine === undefined || !forwardingWorks(ctx, machine.id)) {
    throw new CliError(`herdr cannot reach ${label} through machine forwarding`);
  }
}

/** Bring one instance into use. A container is built or started; a remote
 *  host is never started — what to do is printed. Returns whether it is usable. */
export function ensureOne(ctx: Ctx, name: string): boolean {
  let manifest = readManifest(ctx);
  const found = findInstance(manifest, name);
  if (found === undefined) throw new CliError(`no instance named '${name}'`);
  const synced = syncLabel(ctx, manifest, found);
  if (synced.refused) {
    // `herdr --machine <label>` and the <label>/<pane> rows would name a
    // label herdr does not have
    ctx.err(`Error: ${name}: herdr's machine and the manifest disagree on the label; rename the machine in herdr or set the manifest's label to herdr's`);
    return false;
  }
  manifest = synced.manifest;
  const instance = findInstance(manifest, name) as Instance;
  const label = instance.label;

  if (instance.kind === "container") {
    // the probe below is a plain `ssh <name>`: it reaches the container only
    // through the Include at the top of ~/.ssh/config, so that comes first
    const included = includeOrWarn(ctx, name, () => ensureInclude(ctx, ctx.paths.containersDir));
    const built = container.readState(ctx, name);
    const spec = { port: instance.port, image: instance.image, docker: instance.docker };
    if (built === undefined) {
      container.up(ctx, name, spec);
    } else {
      if (built.image !== instance.image) {
        ctx.err(`Note: ${label} runs docker/${built.image}, the manifest names docker/${instance.image}; apply it with: ${CLI} rebuild ${name} (recreates the container)`);
      }
      if (built.port !== instance.port) {
        ctx.err(`Note: ${label} listens on 127.0.0.1:${built.port}, the manifest says ${instance.port}; apply it with: ${CLI} rebuild ${name} (recreates the container)`);
      }
      if (built.docker !== instance.docker) {
        ctx.err(`Note: ${label} was built with docker: ${built.docker}, the manifest says ${instance.docker}; apply it with: ${CLI} rebuild ${name} (recreates the container)`);
      }
      const first = probe(ctx, name, CONTAINER_DIR);
      if (first.status !== "ok") {
        ctx.err(`${label}: ${probeWord(first)}; starting the container and its herdr server`);
        container.start(ctx, name);
      }
    }
    const after = probe(ctx, name, CONTAINER_DIR);
    const advice = includeAdvice(name, included, after);
    if (advice !== undefined) {
      ctx.err(advice);
      return false;
    }
    if (after.status !== "ok") {
      const detail = after.status === "unreachable" && after.error !== "" ? `: ${after.error}` : "";
      ctx.err(`Error: container ${label} is still not usable (${probeWord(after)}${detail}); rebuild it with: ${CLI} rebuild ${name}`);
      return false;
    }
    if (machineFor(ctx, name) === undefined) container.register(ctx, name, label);
  } else {
    const included = includeOrWarn(ctx, name, () => writeRemoteSshConfig(ctx, instance));
    const result = probe(ctx, name, instance.dir);
    const advice = includeAdvice(name, included, result);
    if (advice !== undefined) {
      ctx.err(advice);
      return false;
    }
    if (result.status !== "ok") {
      for (const line of guidance(ctx, instance, result)) ctx.err(line);
      return false;
    }
    registerRemote(ctx, name, label);
  }
  // herdr's label is what `--machine` takes; it differs from the manifest's
  // when herdr could not take that (another machine has it)
  const shown = machineFor(ctx, name)?.label ?? label;
  if (shown === label) recordAgreed(ctx, name, label);
  ctx.out(`${shown}: ready (herdr --machine ${shown})`);
  return true;
}

/** ensure every instance, or the named ones; one failure does not stop the
 *  others. Returns whether all are usable. */
export function ensure(ctx: Ctx, args: readonly string[]): boolean {
  const manifest = readManifest(ctx);
  const names = args.length === 0 ? manifest.instances.map((i) => i.name) : args.map((a) => resolve(ctx, manifest, a).name);
  let ok = true;
  for (const name of names) {
    try {
      if (!ensureOne(ctx, name)) ok = false;
    } catch (error) {
      if (!(error instanceof CliError)) throw error;
      ctx.err(`Error: ${name}: ${error.message}`);
      ok = false;
    }
  }
  return ok;
}

// --- add -------------------------------------------------------------------------------

export interface AddOptions {
  readonly port?: number;
  readonly label?: string;
  readonly image?: string;
  readonly docker?: boolean;
  readonly identity?: string;
  readonly dir?: string;
}

/** Record a container (`dest` undefined) or a remote host (`dest` =
 *  [user@]host), then ensure it. */
export function add(ctx: Ctx, kind: "container" | "remote", name: string, dest: string | undefined, options: AddOptions): boolean {
  fail(nameProblem(name));
  const manifest = readManifest(ctx);
  if (findInstance(manifest, name) !== undefined) throw new CliError(`instance ${name} is already in the manifest (see: ${CLI} ls)`);
  const label = options.label ?? name;
  checkLabel(ctx, manifest, label, name);
  if (options.port !== undefined) fail(portProblem(options.port));

  let instance: Instance;
  if (kind === "container") {
    if (options.identity !== undefined || options.dir !== undefined) throw new CliError("--identity and --dir are for remote hosts");
    const image = options.image ?? DEFAULT_IMAGE;
    container.requireImage(ctx, image);
    // checked before the manifest is written, so a refused add leaves no entry
    if (options.docker === true) container.requireSysbox(ctx);
    if (container.readState(ctx, name) === undefined) container.refuseForeignProject(ctx, name);
    // each container publishes its own port on 127.0.0.1: two on one port
    // cannot both start
    const taken = new Map(manifest.instances.flatMap((i) => (i.kind === "container" ? [[i.port, i.name] as const] : [])));
    let port = options.port ?? container.readState(ctx, name)?.port;
    if (port === undefined) {
      port = DEFAULT_CONTAINER_PORT;
      while (taken.has(port)) port += 1;
    }
    const holder = taken.get(port);
    if (holder !== undefined) throw new CliError(`port ${port} is already used by container ${holder}; pick another with --port`);
    instance = { kind, name, label, port, image, docker: options.docker ?? false };
  } else {
    if (options.image !== undefined || options.docker !== undefined) throw new CliError("--image and --docker are for containers");
    // its ssh entry could shadow the host's (ssh takes the first match)
    if (container.readState(ctx, name) !== undefined) {
      throw new CliError(`a container ${name} was removed without --purge and keeps its ssh entry, volumes and image; delete them first with: ${CLI} rm --purge ${name}`);
    }
    if (dest === undefined) throw new CliError("a remote host needs <[user@]host>");
    const at = dest.indexOf("@");
    const user = at < 0 ? undefined : dest.slice(0, at);
    const host = at < 0 ? dest : dest.slice(at + 1);
    if (user !== undefined) fail(userProblem(user));
    fail(hostProblem(host));
    const identity = options.identity?.replace(/^~(?=\/|$)/, homedir());
    if (identity !== undefined) fail(identityProblem(identity));
    if (identity !== undefined && !existsSync(identity)) throw new CliError(`identity file not found: ${identity}`);
    const dir = options.dir ?? DEFAULT_DIR;
    fail(dirProblem(dir));
    instance = {
      kind,
      name,
      label,
      host,
      port: options.port ?? DEFAULT_REMOTE_PORT,
      ...(user === undefined ? {} : { user }),
      ...(identity === undefined ? {} : { identity }),
      dir,
    };
  }
  writeManifest(ctx, { instances: [...manifest.instances, instance] });
  ctx.err(`${name}: added to ${ctx.paths.manifestFile}`);
  // back after `rm` (state kept, no container to keep) with another port,
  // image or docker setting: build it as asked, as a plain start would bring
  // back the old one
  if (instance.kind === "container") {
    const built = container.readState(ctx, name);
    if (built !== undefined && (built.port !== instance.port || built.image !== instance.image || built.docker !== instance.docker)) {
      container.up(ctx, name, { port: instance.port, image: instance.image, docker: instance.docker });
    }
  }
  return ensureOne(ctx, name);
}

// --- ls, rename, rebuild, rm -----------------------------------------------------------------

export interface Row {
  readonly name: string;
  readonly label: string;
  readonly kind: Instance["kind"];
  readonly address: string;
  readonly status: Probe;
  readonly registered: boolean;
  readonly image?: string;
  readonly docker?: boolean;
}

export function list(ctx: Ctx): Row[] {
  let manifest = readManifest(ctx);
  const rows: Row[] = [];
  for (const original of manifest.instances) {
    manifest = syncLabel(ctx, manifest, original).manifest;
    const instance = findInstance(manifest, original.name) as Instance;
    if (instance.kind === "remote") {
      try {
        writeRemoteSshConfig(ctx, instance);
      } catch (error) {
        if (!(error instanceof CliError)) throw error;
        ctx.err(`Warning: ${instance.name}: ${error.message}`);
      }
    }
    const machine = machineFor(ctx, instance.name);
    rows.push({
      name: instance.name,
      // what `--machine` takes: herdr's label once it is saved there
      label: machine?.label ?? instance.label,
      kind: instance.kind,
      address: address(instance),
      status: probe(ctx, instance.name, checkoutDir(instance)),
      registered: machine !== undefined,
      ...(instance.kind === "container" ? { image: instance.image, docker: instance.docker } : {}),
    });
  }
  return rows;
}

export function rename(ctx: Ctx, arg: string, label: string): Instance {
  const manifest = readManifest(ctx);
  const instance = resolve(ctx, manifest, arg);
  checkLabel(ctx, manifest, label, instance.name);
  const machine = machineFor(ctx, instance.name);
  if (machine !== undefined) renameMachine(ctx, machine.id, label);
  const next = { ...instance, label };
  writeManifest(ctx, replaceInstance(manifest, next));
  if (machine !== undefined) recordAgreed(ctx, instance.name, label);
  return next;
}

/** Rebuild a container from the manifest's image and docker: recreates the
 *  container, so its agents stop. ensure never does this. */
export function rebuild(ctx: Ctx, arg: string): boolean {
  const instance = resolve(ctx, readManifest(ctx), arg);
  if (instance.kind !== "container") throw new CliError(`${arg} is not a container`);
  container.up(ctx, instance.name, { port: instance.port, image: instance.image, docker: instance.docker });
  return ensureOne(ctx, instance.name);
}

/** Forget the instance and its herdr machine. A container is stopped (purge:
 *  its volumes, image and key too); a remote host's ssh entry is deleted. */
export function remove(ctx: Ctx, arg: string, purge: boolean): { readonly name: string; readonly kind: Instance["kind"]; readonly inManifest: boolean } {
  const manifest = readManifest(ctx);
  let instance: Instance;
  try {
    instance = resolve(ctx, manifest, arg);
  } catch (error) {
    // a container removed without --purge is out of the manifest but keeps
    // its volumes, image and ssh entry: --purge of its name deletes them —
    // only when the name matches no instance or label, so a label never
    // reaches an old container's data
    if (!(error instanceof CliError) || !purge || nameProblem(arg) !== undefined || container.readState(ctx, arg) === undefined) throw error;
    container.down(ctx, arg, true);
    recordAgreed(ctx, arg, undefined);
    return { name: arg, kind: "container", inManifest: false };
  }
  // the label of a live instance that is also the name of a container kept
  // after rm: a purge deletes data either way, so it is not guessed
  if (purge && instance.name !== arg && container.readState(ctx, arg) !== undefined) {
    throw new CliError(
      `'${arg}' is the label of instance ${instance.name} and the name of a container removed without --purge; ` +
        `to remove the instance: ${CLI} rm --purge ${instance.name}; to delete the old container's data, give ${instance.name} another label first`,
    );
  }
  if (instance.kind === "container") container.down(ctx, instance.name, purge);
  else removeRemoteSshConfig(ctx, instance.name);
  const machine = machineFor(ctx, instance.name);
  if (machine !== undefined) removeMachine(ctx, machine.id);
  writeManifest(ctx, withoutInstance(manifest, instance.name));
  recordAgreed(ctx, instance.name, undefined);
  return { name: instance.name, kind: instance.kind, inManifest: true };
}
