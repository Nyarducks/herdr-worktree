// A fake world for the tests: herdr's machine list, ssh answers and docker
// compose, all in memory behind the Runner interface — no stub executables.
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Ctx, Paths } from "../src/context.ts";
import type { Machine } from "../src/herdr.ts";
import type { RunOptions, RunResult } from "../src/proc.ts";
import { after } from "node:test";

/** <checkout>/tmp/tests: git- and docker-ignored, so what a test leaves
 *  stays where the checkout can see and remove it. */
const TEST_TMP = fileURLToPath(new URL("../../../tmp/tests/", import.meta.url));

/** setup() directories, removed when the test file is done (some tests make
 *  directories read-only, so write access is given back first). */
const made: string[] = [];
after(() => {
  const writable = (path: string): void => {
    try {
      chmodSync(path, 0o755);
      for (const entry of readdirSync(path, { withFileTypes: true })) if (entry.isDirectory()) writable(join(path, entry.name));
    } catch {
      // gone or not ours: rmSync with force copes
    }
  };
  for (const dir of made) {
    writable(dir);
    rmSync(dir, { recursive: true, force: true });
  }
});

export interface Call {
  readonly cmd: string;
  readonly args: readonly string[];
  readonly options: RunOptions;
}

export class World {
  machines: Machine[] = [];
  /** what the probe of an ssh Host alias answers: ok, no-server, missing: gh, … */
  probe = new Map<string, string>();
  /** compose projects whose container is running */
  running = new Set<string>();
  sysbox = true;
  /** the user's ssh config and the containers' include: a plain `ssh <name>`
   *  (no -F) reaches a container only when that config includes it */
  userSshConfig = "";
  containersInclude = "";
  remotesInclude = "";
  /** remotes whose HostName does not resolve: ssh alias -> that HostName */
  dnsFails = new Map<string, string>();
  /** herdr refuses `machine rename` */
  renameFails = false;
  /** herdr cannot list its machines (its server is down) */
  listFails = false;
  /** herdr refuses `machine remove` */
  removeFails = false;
  /** `compose build` fails (a broken Dockerfile) */
  buildFails = false;
  /** compose projects not made by the plugin: project -> its compose file */
  foreignProjects = new Map<string, string>();
  /** docker volumes: name -> its compose project label ("" for none). `compose
   *  up` makes the plugin's, `compose down -v` removes them, a plain `down`
   *  keeps them, as Docker does. */
  volumes = new Map<string, string>();
  /** exit status of `exec` runs, per host */
  execCode = new Map<string, number>();
  calls: Call[] = [];
  out: string[] = [];
  err: string[] = [];

  run = (cmd: string, args: readonly string[], options: RunOptions = {}): RunResult => {
    this.calls.push({ cmd, args, options });
    const ok = (stdout = ""): RunResult => ({ code: 0, stdout, stderr: "" });
    const no = (stderr = "", code = 1): RunResult => ({ code, stdout: "", stderr });
    if (cmd === "herdr") return this.herdr(args, ok, no);
    if (cmd === "ssh") return this.ssh(args, ok, no);
    if (cmd === "docker") return this.docker(args, options, ok, no);
    if (cmd === "ssh-keygen") {
      const file = args[args.indexOf("-f") + 1] as string;
      writeFileSync(file, "PRIVATE\n");
      writeFileSync(`${file}.pub`, "ssh-ed25519 AAAA test\n");
      return ok();
    }
    if (cmd === "git") return ok("https://example.invalid/herdr-worktree.git\n");
    return no(`${cmd}: not faked`, 127);
  };

  private herdr(args: readonly string[], ok: (s?: string) => RunResult, no: (s?: string) => RunResult): RunResult {
    const [a, b, c, , e] = args;
    if (a === "machine" && b === "list") return this.listFails ? no("herdr: server not running") : ok(JSON.stringify(this.machines));
    if (a === "machine" && b === "add") {
      this.machines.push({ id: `id-${c}`, label: e as string, target: c as string, enabled: true });
      return ok();
    }
    if (a === "machine" && b === "rename") {
      if (this.renameFails) return no("herdr: rename refused");
      this.machines = this.machines.map((m) => (m.id === c ? { ...m, label: e as string } : m));
      return ok();
    }
    if (a === "machine" && b === "remove") {
      if (this.removeFails) return no("herdr: remove refused");
      this.machines = this.machines.filter((m) => m.id !== c);
      return ok();
    }
    if (a === "--machine") return this.machines.some((m) => m.id === b) ? ok("{}") : no("no such machine");
    return no("herdr: not faked");
  }

  private ssh(args: readonly string[], ok: (s?: string) => RunResult, no: (s?: string, c?: number) => RunResult): RunResult {
    const script = args.at(-1) as string;
    const host = args.at(-2) as string;
    const reachable = (h: string): boolean => this.probe.has(h) || this.running.has(h);
    if (script.includes("for t in git gh jq herdr")) {
      const included = this.running.has(host) ? this.includes(this.containersInclude) : this.probe.has(host) ? this.includes(this.remotesInclude) : true;
      if (!args.includes("-F") && !included) {
        return no(`ssh: Could not resolve hostname ${host}: nodename nor servname provided, or not known`, 255);
      }
      const hostName = this.dnsFails.get(host);
      if (hostName !== undefined) return no(`ssh: Could not resolve hostname ${hostName}: nodename nor servname provided, or not known`, 255);
      if (!reachable(host)) return no(`ssh: connect to host ${host} port 22: Connection refused`, 255);
      return ok(`${this.probe.get(host) ?? "ok"}\n`);
    }
    if (script === "true") return this.running.has(host) ? ok() : no("refused", 255);
    if (script.includes("herdr server")) return ok(); // start the server
    if (script.includes("for tool in")) return ok("ok   git: git version 2\nok   herdr server running\n");
    if (script.startsWith("cd ")) return { code: this.execCode.get(host) ?? 0, stdout: "", stderr: "" };
    return no("ssh: not faked");
  }

  private docker(args: readonly string[], options: RunOptions, ok: (s?: string) => RunResult, no: (s?: string) => RunResult): RunResult {
    if (args[0] === "volume" && args[1] === "ls") {
      return ok([...this.volumes].map(([name, project]) => `${name}\t${project}\n`).join(""));
    }
    if (args[0] === "ps" && args.includes("status=running")) {
      const project = (args.find((a) => a.startsWith("label=com.docker.compose.project=")) ?? "").split("=").at(-1) as string;
      return ok(this.running.has(project) ? `c-${project}\n` : "");
    }
    if (args[0] === "ps") {
      const filter = args[args.indexOf("--filter") + 1] as string;
      const file = this.foreignProjects.get(filter.replace(/^label=com\.docker\.compose\.project=/, ""));
      return ok(file === undefined ? "" : `${file}\n`);
    }
    if (args[0] === "info") return ok(JSON.stringify(this.sysbox ? { runc: {}, "sysbox-runc": {} } : { runc: {} }));
    if (args[0] === "compose") {
      const project = args[args.indexOf("-p") + 1] as string;
      const rest = args.slice(args.indexOf("-p") + 2);
      if (rest[0] === "build" && this.buildFails) return no("build failed");
      if (rest[0] === "up") {
        for (const key of ["ssh-host-keys", "repos", "worktree", "state", "nix", "docker"]) this.volumes.set(`${project}_${key}`, project);
        this.running.add(project);
        this.probe.delete(project);
      }
      if (rest[0] === "down") this.running.delete(project);
      if (rest[0] === "down" && rest.includes("-v")) {
        for (const [volume, owner] of this.volumes) if (owner === project) this.volumes.delete(volume);
      }
      void options;
      return ok();
    }
    return no("docker: not faked");
  }

  private includes(line: string): boolean {
    try {
      return readFileSync(this.userSshConfig, "utf8").split("\n").includes(line);
    } catch {
      return false;
    }
  }

  /** calls whose command line contains every word */
  find(...words: string[]): Call[] {
    return this.calls.filter((c) => {
      const line = [c.cmd, ...c.args].join(" ");
      return words.every((w) => line.includes(w));
    });
  }
}

export interface Setup {
  readonly world: World;
  readonly ctx: Ctx;
  readonly dir: string;
  readonly paths: Paths;
}

/** A Ctx over a temporary directory and a fresh World. Images "default" and
 *  "gpu" exist; the example manifest is the real one. */
export function setup(): Setup {
  // inside the checkout's git-ignored tmp/, never a shared temp dir
  mkdirSync(TEST_TMP, { recursive: true });
  const dir = mkdtempSync(join(TEST_TMP, "instances-"));
  made.push(dir);
  const images = join(dir, "docker");
  for (const image of ["default", "gpu"]) {
    mkdirSync(join(images, image), { recursive: true });
    writeFileSync(join(images, image, "Dockerfile"), "FROM scratch\n");
  }
  const pluginDir = new URL("..", import.meta.url).pathname;
  const paths: Paths = {
    coreDir: join(dir, "core"),
    pluginDir,
    manifestFile: join(dir, "instances.yml"),
    exampleFile: join(pluginDir, "instances.example.yml"),
    imagesDir: images,
    composeFile: join(pluginDir, "compose.yml"),
    containersDir: join(dir, "containers"),
    remotesDir: join(dir, "remotes"),
    labelsFile: join(dir, "labels.json"),
    unregisteredFile: join(dir, "unregistered.json"),
    userSshConfig: join(dir, "home", ".ssh", "config"),
  };
  const world = new World();
  world.userSshConfig = paths.userSshConfig;
  world.containersInclude = `Include ${join(paths.containersDir, "ssh_config")}`;
  world.remotesInclude = `Include ${join(paths.remotesDir, "ssh_config")}`;
  const ctx: Ctx = {
    run: world.run,
    paths,
    out: (line) => world.out.push(line),
    err: (line) => world.err.push(line),
    sleep: () => undefined,
  };
  return { world, ctx, dir, paths };
}
