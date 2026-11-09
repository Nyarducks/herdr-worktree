// ssh: the Include line in the user's config, and the probe that says what
// an instance lacks.
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { CliError, type Ctx } from "./context.ts";

/** Put `Include <dir>/ssh_config` at the top of the user's ssh config (an
 *  Include after a Host block would only apply to that host). */
export function ensureInclude(ctx: Ctx, dir: string): void {
  const configured = ctx.paths.userSshConfig;
  const line = `Include ${join(dir, "ssh_config")}`;
  const yourself = `add this line at the top of the file it comes from:\n  ${line}`;
  // a symlinked config (dotfile managers, home-manager) is edited at its
  // target: replacing the link would detach it from its manager
  let file = configured;
  if (isSymlink(configured)) {
    try {
      file = realpathSync(configured);
    } catch {
      throw new CliError(`${configured} is a link that leads to no file (missing or a loop); ${yourself}`);
    }
  }
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    const current = existsSync(file) ? readFileSync(file, "utf8") : undefined;
    if (current !== undefined && hasInclude(current, join(dir, "ssh_config"))) return;
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    writeFileSync(tmp, `${line}\n${current ?? ""}`);
    chmodSync(tmp, current === undefined ? 0o600 : statSync(file).mode & 0o777);
    renameSync(tmp, file);
  } catch (error) {
    try {
      rmSync(tmp, { force: true });
    } catch {
      // keep the error that brought us here
    }
    const code = (error as NodeJS.ErrnoException).code;
    if (code === undefined) throw error;
    const what = file === configured ? file : `${file} (where ${configured} links to)`;
    throw new CliError(`cannot update ${what}: ${code}; ${yourself}`);
  }
  ctx.err(`added to ${file}: ${line}`);
}

/** Whether an Include directive that applies to every host names <path>,
 *  in any form ssh takes: any case, `=` or spaces, several paths on one line
 *  (home-manager writes them so), quoted or `~/` paths, a trailing comment.
 *  An Include under `Host <pattern>` or `Match <criteria>` applies to those
 *  hosts only, so it counts only before the first such block or under
 *  `Host *` / `Match all`. */
export function hasInclude(text: string, path: string): boolean {
  let everyHost = true;
  for (const raw of text.split(/\r?\n/)) {
    const directive = /^\s*(\w+)(?:\s*=\s*|\s+)(.*?)\s*(?:#.*)?$/.exec(raw);
    if (directive === null) continue;
    const keyword = (directive[1] ?? "").toLowerCase();
    const args = (directive[2] ?? "").split(/\s+/).filter((a) => a !== "");
    if (keyword === "host") everyHost = args.length === 1 && args[0] === "*";
    else if (keyword === "match") everyHost = args.length === 1 && args[0]?.toLowerCase() === "all";
    else if (keyword === "include" && everyHost) {
      const paths = args.map((arg) => arg.replace(/^"(.*)"$|^'(.*)'$/, "$1$2").replace(/^~(?=\/)/, homedir()));
      if (paths.includes(path)) return true;
    }
  }
  return false;
}

function isSymlink(path: string): boolean {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

export type Probe =
  | { readonly status: "ok" }
  | { readonly status: "unreachable"; readonly error: string }
  | { readonly status: "missing"; readonly tools: readonly string[] }
  | { readonly status: "no-checkout" }
  | { readonly status: "no-server" };

/** One word for listings: ok, unreachable, missing:<tools>, no-checkout, no-server. */
export function probeWord(probe: Probe): string {
  return probe.status === "missing" ? `missing:${probe.tools.join(",")}` : probe.status;
}

const REQUIRED_TOOLS = ["git", "gh", "jq", "herdr"] as const;

/** The remote check: tools, the checkout at `dir`, a running herdr server.
 *  Prints one word; `dir` is left unquoted so `~` expands on the host. */
function probeScript(dir: string): string {
  return [
    'miss=""',
    `for t in ${REQUIRED_TOOLS.join(" ")}; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done`,
    'if [ -n "$miss" ]; then echo "missing:$miss"; exit 0; fi',
    `[ -x ${dir}/scripts/list-workers.sh ] || { echo no-checkout; exit 0; }`,
    "if herdr status server --json 2>/dev/null | jq -e .running >/dev/null; then echo ok; else echo no-server; fi",
  ].join("\n");
}

/** Probe instance <name> (an ssh Host alias) over ssh. A new host key is
 *  pinned on first contact (accept-new); a changed one fails. */
export function probe(ctx: Ctx, name: string, dir: string): Probe {
  const result = ctx.run("ssh", [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "StrictHostKeyChecking=accept-new",
    name,
    probeScript(dir),
  ]);
  if (result.code !== 0) {
    const error = result.stderr
      .split("\n")
      .filter((l) => l.trim() !== "" && !l.startsWith("Warning: Permanently added"))
      .at(-1);
    return { status: "unreachable", error: error ?? "" };
  }
  const word = result.stdout.trim().split("\n").at(-1)?.trim() ?? "";
  if (word === "ok" || word === "no-checkout" || word === "no-server") return { status: word };
  if (word.startsWith("missing:")) {
    return { status: "missing", tools: word.slice("missing:".length).trim().split(/\s+/).filter((t) => t !== "") };
  }
  return { status: "unreachable", error: `unexpected answer: ${word}` };
}
