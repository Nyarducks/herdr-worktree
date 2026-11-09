// Remote hosts: an ssh entry per host, and what to tell the user when one
// cannot be used — they are never started from here.
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CLI, type Ctx } from "./context.ts";
import type { RemoteInstance } from "./manifest.ts";
import { ensureInclude, type Probe } from "./ssh.ts";

export function remoteDir(ctx: Ctx, name: string): string {
  return join(ctx.paths.remotesDir, name);
}

/** The host's ssh entry, rewritten from the manifest on every ensure/ls. Keys
 *  already trusted in ~/.ssh/known_hosts are honored; a new one is pinned in
 *  the instance's own known_hosts. */
export function writeRemoteSshConfig(ctx: Ctx, instance: RemoteInstance): void {
  const dir = remoteDir(ctx, instance.name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(ctx.paths.remotesDir, 0o700);
  const lines = [`Host ${instance.name}`, `    HostName ${instance.host}`, `    Port ${instance.port}`];
  if (instance.user !== undefined) lines.push(`    User ${instance.user}`);
  if (instance.identity !== undefined) lines.push(`    IdentityFile ${instance.identity}`, "    IdentitiesOnly yes");
  lines.push(`    UserKnownHostsFile ${join(dir, "known_hosts")} ~/.ssh/known_hosts`, "");
  writeFileSync(join(dir, "ssh_config"), lines.join("\n"));
  writeFileSync(join(ctx.paths.remotesDir, "ssh_config"), `Include ${join(ctx.paths.remotesDir, "*", "ssh_config")}\n`);
  ensureInclude(ctx, ctx.paths.remotesDir);
}

export function removeRemoteSshConfig(ctx: Ctx, name: string): void {
  rmSync(remoteDir(ctx, name), { recursive: true, force: true });
}

export function remoteAddress(instance: RemoteInstance): string {
  return `${instance.user === undefined ? "" : `${instance.user}@`}${instance.host}:${instance.port}`;
}

/** What the user starts or installs on the host, for a probe that is not ok. */
export function guidance(ctx: Ctx, instance: RemoteInstance, probe: Exclude<Probe, { status: "ok" }>): string[] {
  const lines = [`Action needed on ${instance.label} (${remoteAddress(instance)}) — remote hosts are not started from here:`];
  switch (probe.status) {
    case "unreachable":
      lines.push(
        `  - cannot connect over ssh${probe.error === "" ? "" : ` (${probe.error})`}.`,
        "    Start the machine and its sshd, and make sure its authorized_keys holds your key.",
      );
      break;
    case "missing":
      lines.push(
        `  - missing on PATH for non-interactive ssh: ${probe.tools.join(", ")}.`,
        "    Install them (herdr: curl -fsSL https://herdr.dev/install.sh | sh).",
      );
      break;
    case "no-checkout": {
      const origin = ctx.run("git", ["-C", ctx.paths.coreDir, "remote", "get-url", "origin"]);
      const url = origin.code === 0 ? origin.stdout.trim() : "<herdr-worktree repository>";
      lines.push(`  - no herdr-worktree checkout at ${instance.dir}.`, `    Clone it there: git clone ${url} ${instance.dir}`);
      break;
    }
    case "no-server":
      lines.push(
        "  - herdr's server is not running. Start it from the checkout, e.g.:",
        `      cd ${instance.dir} && setsid -f herdr server >~/.config/herdr/headless.log 2>&1 </dev/null`,
      );
      break;
  }
  lines.push(`  Then run: ${CLI} ensure ${instance.name}`);
  return lines;
}
