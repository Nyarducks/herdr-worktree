// The command lines: `instance` (for people and the orchestrator) and
// `hw-plugin` (the contract core calls). Both exit 1 with `Error: …` on a
// CliError and print nothing more on a failure already explained.
import { parseArgs } from "node:util";
import * as container from "./container.ts";
import { CLI, CliError, type Ctx, Reported } from "./context.ts";
import * as contract from "./contract.ts";
import * as instances from "./instances.ts";
import { readManifest } from "./manifest.ts";
import { probeWord } from "./ssh.ts";

export const INSTANCE_HELP = `Usage: instance add container <name> [--port <port>] [--image <image>] [--docker] [--label <label>]
       instance add remote <name> <[user@]host> [--port <port>] [--identity <key>] [--dir <path>] [--label <label>]
       instance ensure [<name-or-label>...]
       instance ls
       instance check <name-or-label>
       instance rename <name-or-label> <new-label>
       instance rebuild <name-or-label>
       instance rm <name-or-label> [--purge]
       instance image ls | image new <image> [--from <image>]

Keeps the herdr-worktree instances this orchestrator drives — dev containers
and remote hosts reached over ssh — in a manifest, and brings them back when
they stop, so a stopped instance does not silently drop out.

Arguments
  <name>          fixed id: ssh Host alias, herdr machine target and, for a
                  container, compose project. ^[a-z][a-z0-9-]{0,31}$. Never
                  changes (rm, then add under a new name).
  <name-or-label> an instance by its name or by its current herdr label.
  <[user@]host>   remote host: IP address or host name, with an optional
                  SSH user.

Commands
  add        record the instance in the manifest, then ensure it. A remote
             host gets an ssh config entry and its host key is pinned on
             first contact (accept-new).
  ensure     every instance, or the named ones. A container that is down is
             started — built first if it never was, else without a rebuild.
             A remote host is never started: what is missing (ssh, tools,
             checkout, herdr server) and how to fix it is printed. Then the
             instance is saved as a herdr machine if it is not one yet. A
             label renamed in herdr is copied into the manifest first. One
             failing instance does not stop the others; exits 1 when any is
             still unavailable.
  ls         one row per instance, tab-separated: name, label, kind, address,
             status (ok, unreachable, no-server, no-checkout,
             missing:<tools>), registered (yes/no), image and docker
             (- for a remote host).
  check      a container's smoke checks over ssh: tools, the herdr server and
             workspace, the checkout's shell tests, herdr's forwarding.
  rename     set the herdr label (herdr machine rename and the manifest).
  rebuild    rebuild a container from the manifest's image and docker:
             recreates the container, so its agents stop. ensure never
             rebuilds; it only notes a difference.
  rm         forget the instance and its herdr machine. A container is
             stopped; a remote host's ssh entry is deleted (nothing on the
             host changes).
  image      ls: docker/<image>/ directories (default is versioned, the others
             git-ignored). new: copy docker/default (or --from) to edit.

Options
  --port <port>     container: SSH port on 127.0.0.1 of this machine (default
                    2222, or the next port no other container uses; one
                    another container has is refused). remote: the host's
                    SSH port (default 22).
  --image <image>   container: build from docker/<image>/ (default \`default\`).
  --docker          container: a Docker daemon inside through Sysbox (no
                    --privileged), so workers can use the repository's own
                    docker compose. Needs Sysbox on the Docker host.
  --label <label>   the herdr label (default <name>): 1-64 characters, no
                    spaces, '/' or '|', unique among herdr's machines
                    ignoring case.
  --identity <key>  remote: private key file on this machine (default: ssh's
                    own keys and agent).
  --dir <path>      remote: the herdr-worktree checkout on the host (default
                    ~/herdr-worktree; ~ expands there).
  --purge           rm of a container: also delete its volumes (logins,
                    clones, worktrees, /nix, inner Docker), image and key;
                    also for a container already removed without it.
  --from <image>    image new: the image to copy (default \`default\`).

Files
  plugins/instances/instances.yml (git-ignored; HW_INSTANCES_FILE overrides):
  the manifest. Its first version is a copy of instances.example.yml, which
  explains every field; the comments above \`instances:\` survive rewrites.
  Container state: ~/.config/herdr-worktree/containers/<name>/ (HW_CONTAINER_DIR);
  remote hosts' ssh entries: ~/.config/herdr-worktree/remotes/ (HW_REMOTES_STATE_DIR),
  both included from ~/.ssh/config.`;

const USAGE = `${INSTANCE_HELP.split("\n\n")[0]}\nEvery argument and option: ${CLI} --help`;

function usage(): never {
  throw new CliError(USAGE);
}

function portOf(value: string | undefined): number | undefined {
  if (value === undefined) return undefined;
  if (!/^[0-9]+$/.test(value)) throw new CliError(`invalid port '${value}'`);
  return Number(value);
}

function one(positionals: readonly string[], count: number): readonly string[] {
  if (positionals.length !== count) usage();
  return positionals;
}

/** `instance …`; returns the exit status. */
export function instanceMain(ctx: Ctx, argv: readonly string[]): number {
  const [command, ...rest] = argv;
  if (command === undefined) usage();
  if (command === "-h" || command === "--help" || command === "help") {
    ctx.out(INSTANCE_HELP);
    return 0;
  }
  readManifest(ctx); // a broken manifest stops every command up front
  switch (command) {
    case "add": {
      const { values, positionals } = parseArgs({
        args: rest,
        allowPositionals: true,
        options: {
          port: { type: "string" },
          image: { type: "string" },
          docker: { type: "boolean" },
          label: { type: "string" },
          identity: { type: "string" },
          dir: { type: "string" },
        },
      });
      const [kind, name, dest] = positionals;
      if ((kind !== "container" && kind !== "remote") || name === undefined) usage();
      if (positionals.length !== (kind === "remote" ? 3 : 2)) usage();
      const port = portOf(values.port);
      const options: instances.AddOptions = {
        ...(port === undefined ? {} : { port }),
        ...(values.label === undefined ? {} : { label: values.label }),
        ...(values.image === undefined ? {} : { image: values.image }),
        ...(values.docker === undefined ? {} : { docker: values.docker }),
        ...(values.identity === undefined ? {} : { identity: values.identity }),
        ...(values.dir === undefined ? {} : { dir: values.dir }),
      };
      return instances.add(ctx, kind, name, dest, options) ? 0 : 1;
    }
    case "ensure":
      return instances.ensure(ctx, rest) ? 0 : 1;
    case "ls":
      one(rest, 0);
      for (const row of instances.list(ctx)) {
        ctx.out(
          [
            row.name,
            row.label,
            row.kind,
            row.address,
            probeWord(row.status),
            row.registered ? "yes" : "no",
            row.image ?? "-",
            row.docker === undefined ? "-" : row.docker ? "yes" : "no",
          ].join("\t"),
        );
      }
      return 0;
    case "check": {
      const [arg] = one(rest, 1);
      const instance = instances.resolve(ctx, readManifest(ctx), arg as string);
      if (instance.kind !== "container") throw new CliError(`${arg} is not a container (check is for containers)`);
      const lines = container.check(ctx, instance.name);
      for (const line of lines) ctx.out(line.text);
      return lines.some((l) => l.ok === false) ? 1 : 0;
    }
    case "rename": {
      const [arg, label] = one(rest, 2);
      const renamed = instances.rename(ctx, arg as string, label as string);
      ctx.out(`${renamed.name}: now labeled ${renamed.label}`);
      return 0;
    }
    case "rebuild": {
      const [arg] = one(rest, 1);
      return instances.rebuild(ctx, arg as string) ? 0 : 1;
    }
    case "rm": {
      const { values, positionals } = parseArgs({ args: rest, allowPositionals: true, options: { purge: { type: "boolean" } } });
      const [arg] = one(positionals, 1);
      const removed = instances.remove(ctx, arg as string, values.purge === true);
      ctx.out(
        removed.inManifest
          ? `${removed.name}: removed from the manifest${values.purge === true && removed.kind === "container" ? " (volumes, image and key deleted)" : ""}`
          : `${removed.name}: deleted the volumes, image and key of this container (no longer in the manifest)`,
      );
      return 0;
    }
    case "image": {
      const [sub, ...args] = rest;
      if (sub === "ls") {
        one(args, 0);
        for (const entry of container.listImages(ctx)) ctx.out(`${entry.image}\t${entry.versioned ? "versioned" : "local"}`);
        return 0;
      }
      if (sub === "new") {
        const { values, positionals } = parseArgs({ args, allowPositionals: true, options: { from: { type: "string" } } });
        const [image] = one(positionals, 1);
        container.newImage(ctx, image as string, values.from);
        ctx.out(`docker/${image}: copied from docker/${values.from ?? "default"} (git-ignored). Edit its Dockerfile, then: ${CLI} add container <name> --image ${image}`);
        return 0;
      }
      return usage();
    }
    default:
      return usage();
  }
}

export const HW_PLUGIN_HELP = `Usage: hw-plugin describe
       hw-plugin machines
       hw-plugin ensure <name-or-label>
       hw-plugin exec <name-or-label> -- <command> [args...]
       hw-plugin disable | enable

The herdr-worktree plugin contract (version ${contract.CONTRACT_VERSION}), called by core
(scripts/lib/plugins.sh). describe and machines print JSON on stdout; exec
passes the remote command's output and exit status through; messages go to
stderr. disable (before plugins.sh disable) takes the plugin's machines out of
herdr; enable (after plugins.sh enable) brings those back.`;

/** `hw-plugin …`; returns the exit status. */
export function hwPluginMain(ctx: Ctx, argv: readonly string[]): number {
  const [command, ...rest] = argv;
  switch (command) {
    case "describe":
      ctx.out(JSON.stringify(contract.describe()));
      return 0;
    case "machines":
      ctx.out(JSON.stringify(contract.machines(ctx)));
      return 0;
    case "ensure": {
      const [arg] = one(rest, 1);
      return contract.ensure(ctx, arg as string) ? 0 : 1;
    }
    case "exec": {
      const [arg, separator, ...command_] = rest;
      if (arg === undefined || separator !== "--") throw new CliError(HW_PLUGIN_HELP);
      return contract.exec(ctx, arg, command_);
    }
    case "disable":
      one(rest, 0);
      return contract.disable(ctx) ? 0 : 1;
    case "enable":
      one(rest, 0);
      return contract.enable(ctx) ? 0 : 1;
    case "-h":
    case "--help":
    case "help":
      ctx.out(HW_PLUGIN_HELP);
      return 0;
    default:
      throw new CliError(HW_PLUGIN_HELP);
  }
}

/** Run a main, turning errors into exit statuses. */
export function runMain(ctx: Ctx, main: (ctx: Ctx, argv: readonly string[]) => number, argv: readonly string[]): number {
  try {
    return main(ctx, argv);
  } catch (error) {
    if (error instanceof Reported) return 1;
    if (error instanceof CliError) {
      ctx.err(error.message.startsWith("Usage:") ? error.message : `Error: ${error.message}`);
      return 1;
    }
    if (error instanceof TypeError && "code" in error && String(error.code).startsWith("ERR_PARSE_ARGS")) {
      ctx.err(`Error: ${error.message}\n${USAGE}`);
      return 1;
    }
    throw error;
  }
}
