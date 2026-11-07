// instances.yml: the instances this orchestrator drives. Read with a real
// YAML parser and checked field by field; written back with the comments
// above `instances:` kept (a first write starts from instances.example.yml).
import { chmodSync, copyFileSync, existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { isMap, isScalar, isSeq, LineCounter, parseDocument, type Scalar, stringify, type Node } from "yaml";
import { CliError, type Ctx } from "./context.ts";
import { dirProblem, hostProblem, identityProblem, imageProblem, labelProblem, nameProblem, portProblem, userProblem } from "./validate.ts";

export const DEFAULT_CONTAINER_PORT = 2222;
export const DEFAULT_REMOTE_PORT = 22;
export const DEFAULT_IMAGE = "default";
export const DEFAULT_DIR = "~/herdr-worktree";

export interface ContainerInstance {
  readonly kind: "container";
  readonly name: string;
  readonly label: string;
  readonly port: number;
  readonly image: string;
  readonly docker: boolean;
}

export interface RemoteInstance {
  readonly kind: "remote";
  readonly name: string;
  readonly label: string;
  readonly host: string;
  readonly port: number;
  readonly user?: string;
  readonly identity?: string;
  readonly dir: string;
}

export type Instance = ContainerInstance | RemoteInstance;

export interface Manifest {
  readonly instances: readonly Instance[];
}

const CONTAINER_FIELDS = ["name", "kind", "label", "port", "image", "docker"] as const;
const REMOTE_FIELDS = ["name", "kind", "label", "host", "port", "user", "identity", "dir"] as const;

class Location {
  readonly file: string;
  readonly counter: LineCounter;
  constructor(file: string, counter: LineCounter) {
    this.file = file;
    this.counter = counter;
  }
  fail(node: Node | null | undefined, message: string): never {
    const offset = node?.range?.[0];
    const line = offset === undefined ? undefined : this.counter.linePos(offset).line;
    throw new CliError(`${this.file}${line === undefined ? "" : `:${line}`}: ${message}`);
  }
}

/** Parse and check manifest text. `file` only names the source in errors. */
export function parseManifest(text: string, file: string): Manifest {
  const counter = new LineCounter();
  const doc = parseDocument(text, { lineCounter: counter, uniqueKeys: true });
  // explicitly typed, so at.fail (never) narrows the checks below
  const at: Location = new Location(basename(file), counter);
  const first = doc.errors[0];
  if (first !== undefined) {
    const line = first.linePos?.[0]?.line;
    throw new CliError(`${basename(file)}${line === undefined ? "" : `:${line}`}: ${first.message.split("\n")[0]}`);
  }
  const root = doc.contents;
  if (root === null) return { instances: [] };
  if (!isMap(root)) at.fail(root, "expected `instances:` at the top");
  let list: Node | null | undefined;
  for (const pair of root.items) {
    const key = isScalar(pair.key) ? String(pair.key.value) : "";
    if (key !== "instances") at.fail(pair.key as Node, `unknown top-level key '${key}' (only \`instances:\`)`);
    list = pair.value as Node | null;
  }
  if (list === undefined) at.fail(root, "no `instances:` key");
  if (list === null || (isScalar(list) && list.value === null)) return { instances: [] };
  if (!isSeq(list)) at.fail(list, "`instances:` must be a list of `- name: …` entries");

  const instances: Instance[] = [];
  const names = new Set<string>();
  const labels = new Set<string>();
  for (const item of list.items) {
    const instance = parseInstance(item as Node, at);
    if (names.has(instance.name)) at.fail(item as Node, `duplicate instance name '${instance.name}'`);
    names.add(instance.name);
    // labels are unique ignoring case, as herdr's machines are told apart
    const label = instance.label.toLowerCase();
    if (labels.has(label)) at.fail(item as Node, `label '${instance.label}' is used twice (labels are unique, ignoring case)`);
    labels.add(label);
    instances.push(instance);
  }
  return { instances };
}

function parseInstance(item: Node, at: Location): Instance {
  if (!isMap(item)) at.fail(item, "an entry must be a map of `key: value` fields");
  const values = new Map<string, { node: Node; value: unknown }>();
  for (const pair of item.items) {
    const key = isScalar(pair.key) ? String(pair.key.value) : "";
    const node = pair.value as Node | null;
    if (node === null || !isScalar(node)) at.fail(pair.key as Node, `'${key}' must be a single value (nested maps and lists are not supported)`);
    values.set(key, { node, value: node.value });
  }
  const str = (key: string, required: boolean): string | undefined => {
    const field = values.get(key);
    if (field === undefined || field.value === null) {
      if (required) at.fail(item, `missing required field '${key}'`);
      return undefined;
    }
    if (typeof field.value !== "string" && typeof field.value !== "number") at.fail(field.node, `'${key}' must be text`);
    // a number-looking value (007, 1.10) is kept as written, not as the
    // number YAML reads it as
    return typeof field.value === "number" ? ((field.node as Scalar).source ?? String(field.value)) : field.value;
  };
  const int = (key: string, fallback: number): number => {
    const field = values.get(key);
    if (field === undefined || field.value === null) return fallback;
    if (typeof field.value !== "number" || !Number.isInteger(field.value)) at.fail(field.node, `'${key}' must be an integer`);
    const problem = portProblem(field.value);
    if (problem !== undefined) at.fail(field.node, problem);
    return field.value;
  };
  const bool = (key: string, fallback: boolean): boolean => {
    const field = values.get(key);
    if (field === undefined || field.value === null) return fallback;
    if (typeof field.value !== "boolean") at.fail(field.node, `'${key}' must be true or false`);
    return field.value;
  };
  const check = (key: string, problem: string | undefined): void => {
    if (problem !== undefined) at.fail(values.get(key)?.node ?? item, problem);
  };

  const name = str("name", true) as string;
  check("name", nameProblem(name));
  const kind = str("kind", true);
  const label = str("label", false) ?? name;
  check("label", labelProblem(label));

  const allowed: readonly string[] = kind === "container" ? CONTAINER_FIELDS : kind === "remote" ? REMOTE_FIELDS : [];
  if (allowed.length === 0) at.fail(values.get("kind")?.node ?? item, `kind must be 'container' or 'remote', not '${kind}'`);
  for (const [key, { node }] of values) {
    if (!allowed.includes(key)) at.fail(node, `unknown field '${key}' for a ${kind} (see instances.example.yml)`);
  }

  if (kind === "container") {
    const image = str("image", false) ?? DEFAULT_IMAGE;
    check("image", imageProblem(image));
    return { kind, name, label, port: int("port", DEFAULT_CONTAINER_PORT), image, docker: bool("docker", false) };
  }
  const host = str("host", true) as string;
  check("host", hostProblem(host));
  const user = str("user", false);
  if (user !== undefined) check("user", userProblem(user));
  const dir = str("dir", false) ?? DEFAULT_DIR;
  check("dir", dirProblem(dir));
  const identity = str("identity", false);
  if (identity !== undefined) check("identity", identityProblem(identity));
  return {
    kind: "remote",
    name,
    label,
    host,
    port: int("port", DEFAULT_REMOTE_PORT),
    ...(user === undefined ? {} : { user }),
    ...(identity === undefined ? {} : { identity }),
    dir,
  };
}

/** The manifest's text: `header` (the comments above `instances:`) and the
 *  entries, every field written out in a fixed order. */
export function serializeManifest(manifest: Manifest, header: string): string {
  const entries = manifest.instances.map((i) =>
    i.kind === "container"
      ? { name: i.name, kind: i.kind, label: i.label, port: i.port, image: i.image, docker: i.docker }
      : {
          name: i.name,
          kind: i.kind,
          label: i.label,
          host: i.host,
          port: i.port,
          ...(i.user === undefined ? {} : { user: i.user }),
          ...(i.identity === undefined ? {} : { identity: i.identity }),
          dir: i.dir,
        },
  );
  const body = entries.length === 0 ? "instances: []\n" : stringify({ instances: entries }, { lineWidth: 0 });
  return header + body;
}

/** Everything above the first `instances:` line. */
export function headerOf(text: string): string {
  const match = /^instances:/m.exec(text);
  return match === null ? "" : text.slice(0, match.index);
}

const FALLBACK_HEADER =
  "# herdr-worktree instances (git-ignored). Every field is explained in\n" +
  "# plugins/instances/instances.example.yml.\n";

export function readManifest(ctx: Ctx): Manifest {
  const file = ctx.paths.manifestFile;
  if (!existsSync(file)) return { instances: [] };
  return parseManifest(readFileSync(file, "utf8"), file);
}

/** Write the manifest atomically; the first write copies the example so
 *  the field reference travels with it. */
export function writeManifest(ctx: Ctx, manifest: Manifest): void {
  const file = ctx.paths.manifestFile;
  if (!existsSync(file) && existsSync(ctx.paths.exampleFile)) {
    copyFileSync(ctx.paths.exampleFile, file);
    chmodSync(file, 0o600);
    ctx.err(`created ${file} from instances.example.yml`);
  }
  const current = existsSync(file) ? readFileSync(file, "utf8") : "";
  const header = headerOf(current) || FALLBACK_HEADER;
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, serializeManifest(manifest, header), { mode: 0o600 });
  renameSync(tmp, file);
}

export function findInstance(manifest: Manifest, name: string): Instance | undefined {
  return manifest.instances.find((i) => i.name === name);
}

export function replaceInstance(manifest: Manifest, next: Instance): Manifest {
  return { instances: manifest.instances.map((i) => (i.name === next.name ? next : i)) };
}

export function withoutInstance(manifest: Manifest, name: string): Manifest {
  return { instances: manifest.instances.filter((i) => i.name !== name) };
}
