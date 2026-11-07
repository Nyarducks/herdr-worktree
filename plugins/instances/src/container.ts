// Dev containers (compose.yml, docker/<image>/): one compose project per
// instance, reached over ssh as a herdr machine. State per container lives in
// <containersDir>/<name>/ (the same files the shell version kept):
//   id_ed25519, id_ed25519.pub, known_hosts, ssh_config, port, image, docker
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";
import { CliError, CLI, type Ctx } from "./context.ts";
import { addMachine, forwardingWorks, machineFor, removeMachine } from "./herdr.ts";
import { DEFAULT_IMAGE } from "./manifest.ts";
import { imageProblem } from "./validate.ts";

const REMOTE_USER = "dev";

export interface ContainerSpec {
  readonly port: number;
  readonly image: string;
  readonly docker: boolean;
}

export function envDir(ctx: Ctx, name: string): string {
  return join(ctx.paths.containersDir, name);
}

/** What the container was last built with; undefined before the first up. */
export function readState(ctx: Ctx, name: string): ContainerSpec | undefined {
  const dir = envDir(ctx, name);
  const read = (file: string): string | undefined =>
    existsSync(join(dir, file)) ? readFileSync(join(dir, file), "utf8").trim() : undefined;
  const port = read("port");
  if (port === undefined) return undefined;
  return { port: Number(port), image: read("image") ?? DEFAULT_IMAGE, docker: read("docker") === "1" };
}

function writeState(ctx: Ctx, name: string, spec: ContainerSpec): void {
  const dir = envDir(ctx, name);
  writeFileSync(join(dir, "port"), `${spec.port}\n`);
  writeFileSync(join(dir, "image"), `${spec.image}\n`);
  writeFileSync(join(dir, "docker"), `${spec.docker ? 1 : 0}\n`);
}

// --- images -------------------------------------------------------------------

export function imageDir(ctx: Ctx, image: string): string {
  return join(ctx.paths.imagesDir, image);
}

export function imageExists(ctx: Ctx, image: string): boolean {
  return imageProblem(image) === undefined && existsSync(join(imageDir(ctx, image), "Dockerfile"));
}

export function requireImage(ctx: Ctx, image: string): void {
  const problem = imageProblem(image);
  if (problem !== undefined) throw new CliError(problem);
  if (!imageExists(ctx, image)) {
    throw new CliError(`no image '${image}': docker/${image}/Dockerfile not found (see: ${CLI} image ls)`);
  }
}

export interface ImageEntry {
  readonly image: string;
  /** docker/default is versioned; every other docker/<image>/ is git-ignored */
  readonly versioned: boolean;
}

export function listImages(ctx: Ctx): ImageEntry[] {
  if (!existsSync(ctx.paths.imagesDir)) return [];
  return readdirSync(ctx.paths.imagesDir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(ctx.paths.imagesDir, d.name, "Dockerfile")))
    .map((d) => ({ image: d.name, versioned: d.name === DEFAULT_IMAGE }))
    .sort((a, b) => a.image.localeCompare(b.image));
}

/** Copy docker/<from> to the git-ignored docker/<image>/ to edit. */
export function newImage(ctx: Ctx, image: string, from: string = DEFAULT_IMAGE): void {
  const problem = imageProblem(image);
  if (problem !== undefined) throw new CliError(problem);
  if (image === DEFAULT_IMAGE) throw new CliError(`'${DEFAULT_IMAGE}' is the versioned image; pick another name`);
  if (existsSync(imageDir(ctx, image))) throw new CliError(`docker/${image} already exists`);
  requireImage(ctx, from);
  cpSync(imageDir(ctx, from), imageDir(ctx, image), { recursive: true });
}

// --- compose and ssh -------------------------------------------------------------

function compose(ctx: Ctx, name: string, spec: ContainerSpec, args: readonly string[], input?: string): number {
  const result = ctx.run("docker", ["compose", "-f", ctx.paths.composeFile, "-p", name, ...args], {
    env: {
      HW_CORE_DIR: ctx.paths.coreDir,
      HW_IMAGE_DIR: imageDir(ctx, spec.image),
      HW_SSH_PORT: String(spec.port),
      HW_DOCKER: spec.docker ? "1" : "0",
      HW_RUNTIME: spec.docker ? "sysbox-runc" : "runc",
    },
    output: "stderr",
    ...(input === undefined ? {} : { input }),
  });
  return result.code;
}

function mustCompose(ctx: Ctx, name: string, spec: ContainerSpec, args: readonly string[], input?: string): void {
  if (compose(ctx, name, spec, args, input) !== 0) {
    throw new CliError(`docker compose ${args.join(" ")} failed for ${name}`);
  }
}

/** Docker inside needs the sysbox-runc runtime on the Docker host (ADR-0017);
 *  there is no --privileged fallback. */
export function requireSysbox(ctx: Ctx): void {
  const result = ctx.run("docker", ["info", "--format", "{{json .Runtimes}}"]);
  let runtimes: unknown;
  try {
    runtimes = JSON.parse(result.stdout);
  } catch {
    runtimes = undefined;
  }
  if (result.code !== 0 || typeof runtimes !== "object" || runtimes === null || !("sysbox-runc" in runtimes)) {
    throw new CliError(
      "docker: true needs the sysbox-runc runtime on the Docker host (see plugins/instances/README.md, \"Docker inside\")",
    );
  }
}

/** Key, ssh config and the include file for <name>. */
function writeEnvFiles(ctx: Ctx, name: string, port: number): void {
  const dir = envDir(ctx, name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(ctx.paths.containersDir, 0o700);
  chmodSync(dir, 0o700);
  if (!existsSync(join(dir, "id_ed25519"))) {
    const keygen = ctx.run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", `herdr-worktree-${name}`, "-f", join(dir, "id_ed25519")]);
    if (keygen.code !== 0) throw new CliError(`ssh-keygen failed: ${keygen.stderr.trim()}`);
  }
  writeFileSync(
    join(dir, "ssh_config"),
    [
      `Host ${name}`,
      "    HostName 127.0.0.1",
      `    Port ${port}`,
      `    User ${REMOTE_USER}`,
      `    IdentityFile ${join(dir, "id_ed25519")}`,
      "    IdentitiesOnly yes",
      `    UserKnownHostsFile ${join(dir, "known_hosts")}`,
      `    HostKeyAlias ${name}`,
      "",
    ].join("\n"),
  );
  writeFileSync(join(ctx.paths.containersDir, "ssh_config"), `Include ${join(ctx.paths.containersDir, "*", "ssh_config")}\n`);
}

/** Write the public key in through `exec` stdin: nothing is bind-mounted from
 *  the host, and `docker cp` fails on sysbox-runc containers. */
function installPubkey(ctx: Ctx, name: string, spec: ContainerSpec): void {
  const key = `/etc/ssh/authorized_keys/${REMOTE_USER}`;
  const pub = readFileSync(join(envDir(ctx, name), "id_ed25519.pub"), "utf8");
  mustCompose(ctx, name, spec, ["exec", "-T", "-u", "root", "dev", "sh", "-c", `cat > ${key} && chown root:root ${key} && chmod 0644 ${key}`], pub);
}

function sshArgs(ctx: Ctx, name: string, hostKeyChecking: "yes" | "accept-new", timeout: number): string[] {
  return [
    "-F", join(envDir(ctx, name), "ssh_config"),
    "-o", "BatchMode=yes",
    "-o", `StrictHostKeyChecking=${hostKeyChecking}`,
    "-o", `ConnectTimeout=${timeout}`,
    name,
  ];
}

/** Wait for sshd and record its host key on first contact (accept-new); a
 *  changed key fails instead of being replaced. */
function pinHostKey(ctx: Ctx, name: string): void {
  for (let i = 0; i < 60; i++) {
    if (ctx.run("ssh", [...sshArgs(ctx, name, "accept-new", 2), "true"]).code === 0) return;
    ctx.sleep(1000);
  }
  throw new CliError(
    `cannot log in to ${name} over ssh. If its volumes were recreated, the pinned host key no longer matches: remove the instance with --purge and add it again.`,
  );
}

/** Start the herdr server from the checkout (setsid -f, every fd redirected
 *  so ssh returns) and make sure a workspace labeled herdr-worktree is open;
 *  the server's lone initial "~" workspace is replaced. Runs remotely. */
const START_HERDR_SERVER = `set -u
wt="\${HOME}/herdr-worktree"
running() { herdr status server --json 2>/dev/null | jq -e .running >/dev/null; }
if ! running; then
  mkdir -p "\${HOME}/.config/herdr"
  (cd "\${wt}" && exec setsid -f herdr server) >"\${HOME}/.config/herdr/headless.log" 2>&1 </dev/null
  for i in $(seq 1 20); do running && break; sleep 0.5; done
  running || { echo "herdr server did not start; see ~/.config/herdr/headless.log" >&2; exit 1; }
fi
list="$(herdr workspace list)"
jq -e '.result.workspaces[] | select(.label == "herdr-worktree")' <<< "\${list}" >/dev/null && exit 0
herdr workspace create --cwd "\${wt}" --label herdr-worktree --no-focus >/dev/null
home_ws="$(jq -r '[.result.workspaces[]] | if length == 1 and .[0].label == "~" and .[0].pane_count == 1 then .[0].workspace_id else empty end' <<< "\${list}")"
if [ -n "\${home_ws}" ]; then herdr workspace close "\${home_ws}" >/dev/null; fi`;

function startHerdrServer(ctx: Ctx, name: string): void {
  const result = ctx.run("ssh", [...sshArgs(ctx, name, "yes", 10), START_HERDR_SERVER], { output: "stderr" });
  if (result.code !== 0) throw new CliError(`could not start herdr's server in ${name}`);
}

// --- operations -------------------------------------------------------------------

/** The named volumes compose.yml declares; compose creates each as
 *  `<project>_<key>`. */
function composeVolumeKeys(ctx: Ctx): string[] {
  const doc: unknown = parse(readFileSync(ctx.paths.composeFile, "utf8"));
  const volumes = typeof doc === "object" && doc !== null ? (doc as { volumes?: unknown }).volumes : undefined;
  return typeof volumes === "object" && volumes !== null ? Object.keys(volumes) : [];
}

/** Compose finds a project's containers and volumes by its name, not by its
 *  file: building a first container <name> while another compose file has a
 *  project <name> would retag its image, recreate its container, or mount its
 *  volumes (`<name>_state`, …) — which `rm --purge` would then delete. Called
 *  only for a name the plugin has no build of, so any such project is
 *  someone else's. */
export function refuseForeignProject(ctx: Ctx, name: string): void {
  const result = ctx.run("docker", [
    "ps", "-a",
    "--filter", `label=com.docker.compose.project=${name}`,
    "--format", '{{.Label "com.docker.compose.project.config_files"}}',
  ]);
  if (result.code !== 0) throw new CliError(`docker ps failed: ${result.stderr.trim()}`);
  const files = result.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
  const foreign = files.find((l) => l !== ctx.paths.composeFile);
  if (foreign !== undefined) {
    throw new CliError(`a docker compose project '${name}' from ${foreign} already exists; pick another instance name`);
  }
  // the plugin's own project (its state was lost): its volumes are its own
  if (files.length > 0) return;
  // a project brought down keeps its volumes, which carry no compose file;
  // and compose mounts <name>_<key> by name, whoever made it
  const mounted = new Set(composeVolumeKeys(ctx).map((key) => `${name}_${key}`));
  const volumes = ctx.run("docker", ["volume", "ls", "--format", '{{.Name}}\t{{.Label "com.docker.compose.project"}}']);
  if (volumes.code !== 0) throw new CliError(`docker volume ls failed: ${volumes.stderr.trim()}`);
  const left = volumes.stdout
    .split("\n")
    .map((l) => l.split("\t"))
    .filter(([volume = "", project = ""]) => volume.trim() !== "" && (project.trim() === name || mounted.has(volume.trim())))
    .map(([volume = ""]) => volume.trim());
  if (left.length > 0) {
    throw new CliError(`docker volumes of a compose project '${name}' already exist (${left.join(", ")}); pick another instance name, or remove them if they are no longer needed`);
  }
}

/** Build (if needed) and start <name> with <spec>; remembered for later starts. */
export function up(ctx: Ctx, name: string, spec: ContainerSpec): void {
  requireImage(ctx, spec.image);
  if (spec.docker) requireSysbox(ctx);
  // build first: a failed build changes nothing, so the state, ssh_config and
  // the running container still agree on the last build and ensure keeps
  // noting what the manifest asks for. Once built, the spec is recorded
  // before the start, so a start that fails (a port taken on the host) is
  // retried by ensure with the same spec.
  if (readState(ctx, name) === undefined) refuseForeignProject(ctx, name);
  mustCompose(ctx, name, spec, ["build"]);
  writeEnvFiles(ctx, name, spec.port);
  writeState(ctx, name, spec);
  mustCompose(ctx, name, spec, ["up", "-d"]);
  installPubkey(ctx, name, spec);
  pinHostKey(ctx, name);
  startHerdrServer(ctx, name);
  ctx.err(`${name}: up on 127.0.0.1:${spec.port} from docker/${spec.image}`);
}

/** Bring a stopped container back without rebuilding (a rebuild would
 *  recreate a running container); a running one is left as it is. */
export function start(ctx: Ctx, name: string): void {
  const spec = readState(ctx, name);
  if (spec === undefined) throw new CliError(`unknown container '${name}' (never built)`);
  if (spec.docker) requireSysbox(ctx);
  mustCompose(ctx, name, spec, ["up", "-d"]);
  installPubkey(ctx, name, spec);
  pinHostKey(ctx, name);
  startHerdrServer(ctx, name);
  ctx.err(`${name}: started on 127.0.0.1:${spec.port}`);
}

/** Save <name> as a herdr machine shown as <label> (ensure has already put
 *  the containers' Include into ~/.ssh/config); check herdr reaches it. */
export function register(ctx: Ctx, name: string, label: string): void {
  if (readState(ctx, name) === undefined) throw new CliError(`unknown container '${name}' (never built)`);
  let machine = machineFor(ctx, name);
  if (machine === undefined) {
    addMachine(ctx, name, label);
    machine = machineFor(ctx, name);
  }
  if (machine === undefined || !forwardingWorks(ctx, machine.id)) {
    throw new CliError(`herdr cannot reach ${name} through machine forwarding`);
  }
}

/** Stop <name>; with purge also its volumes, image, herdr machine and key. */
export function down(ctx: Ctx, name: string, purge: boolean): void {
  const spec = readState(ctx, name);
  if (spec === undefined) {
    // never built by the plugin (a failed first build writes nothing): no
    // compose call, since a project of that name would be someone else's
    if (!purge) return;
    const machine = machineFor(ctx, name);
    if (machine !== undefined) removeMachine(ctx, machine.id);
    rmSync(envDir(ctx, name), { recursive: true, force: true });
    return;
  }
  if (!purge) {
    mustCompose(ctx, name, spec, ["down"]);
    return;
  }
  mustCompose(ctx, name, spec, ["down", "-v", "--rmi", "local"]);
  const machine = machineFor(ctx, name);
  if (machine !== undefined) removeMachine(ctx, machine.id);
  rmSync(envDir(ctx, name), { recursive: true, force: true });
}

export interface CheckLine {
  readonly ok: boolean | "skip";
  readonly text: string;
}

/** The smoke checks over ssh: tools, the herdr server and workspace, the
 *  checkout's shell tests, and herdr's forwarding once registered. */
const CHECK_SCRIPT = `set -u
for tool in git gh jq herdr nix node docker bats; do
  if v="$(\${tool} --version 2>/dev/null | head -1)"; then echo "ok   \${tool}: \${v}"; else echo "fail \${tool}: not found"; fi
done
if herdr status server --json 2>/dev/null | jq -e .running >/dev/null; then echo "ok   herdr server running"; else echo "fail herdr server not running"; fi
if herdr workspace list 2>/dev/null | jq -e '.result.workspaces[] | select(.label == "herdr-worktree")' >/dev/null; then echo "ok   herdr-worktree workspace"; else echo "fail herdr-worktree workspace missing"; fi
cd ~/herdr-worktree || { echo "fail checkout missing"; exit 0; }
for t in tests/scripts/*.bats tests/scripts/lib/*.bats; do
  if bats "\${t}" >/dev/null 2>&1; then echo "ok   \${t}"; else echo "fail \${t}"; fi
done`;

export function check(ctx: Ctx, name: string): CheckLine[] {
  if (readState(ctx, name) === undefined) throw new CliError(`unknown container '${name}' (never built)`);
  const result = ctx.run("ssh", [...sshArgs(ctx, name, "yes", 10), CHECK_SCRIPT]);
  const lines: CheckLine[] = result.stdout
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => ({ ok: l.startsWith("ok"), text: l }));
  if (result.code !== 0) lines.push({ ok: false, text: `fail ssh to ${name}` });
  const machine = machineFor(ctx, name);
  if (machine === undefined) {
    lines.push({ ok: "skip", text: "skip herdr machine forwarding (not registered)" });
  } else {
    const ok = forwardingWorks(ctx, machine.id);
    lines.push({ ok, text: `${ok ? "ok  " : "fail"} herdr --machine ${machine.label} workspace list` });
  }
  return lines;
}
