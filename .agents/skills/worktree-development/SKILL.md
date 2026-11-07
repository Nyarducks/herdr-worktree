---
name: worktree-development
description: Develop any repository other than herdr-worktree by dispatching a dedicated worker agent via herdr — one herdr workspace per repo, one tab per task. Ask the user which agent kind and which repository when unspecified.
---

# Worktree Development (herdr dispatch)

Any repository **other than herdr-worktree itself** is developed through
this skill: a separate worker agent process spawned via `herdr`, with its
cwd bound to a fresh worktree so the target repo's own `.agents/skills`
and `AGENTS.md`/`CLAUDE.md` apply. The orchestrator never edits other
repos in-process. (For the herdr-worktree repo itself, use
`development` instead.)

Steering a worker that is already running — moving to its pane,
relaying an instruction to it, checking status — is `herdr-control`.

## Language

Think in English; reply to the user in the user's natural language.
Every dispatch passes that language to the worker with
`--reply-lang <language>` (e.g. `--reply-lang Japanese`), so the worker
also thinks in English but replies in the user's language. Write the
task text in English, keeping quoted text, identifiers and file names
verbatim.

## Before dispatching — confirm with the user

If the request does not specify both of these, ask *before* dispatching
via your agent's ask-question tool — the `ask*question` variant it
exposes (`AskUserQuestion`, `ask_user_question`, `ask_question`, …).
Never default silently.

- **Agent kind** — offer these options (mapped to `--kind`):
  Claude Code → `claude`, Codex → `codex`, Devin → `devin`,
  Antigravity → `agy`, pi → `pi`.
- **Repository** — ask for the repository *name*. Offer the base clones
  already under `repos/` as options; accept a bare name or `owner/name`.

When an enabled plugin provides other machines (`scripts/plugins.sh
machines`: dev containers, remote hosts), also settle **where** the worker runs: here, or on a named
machine. If the request names one ("in hw-a", "on the client-B
container"), use it; if it names none, dispatch here. Ask only when the
request is ambiguous about it (e.g. the repository is cloned on several
machines and nothing points to one) — the machines hold different Git
accounts, so never guess.

## Precondition

```bash
[[ "${HERDR_ENV:-}" == "1" ]] && command -v herdr >/dev/null
```

If this fails, tell the user herdr isn't available — there is no
in-process fallback for other repositories.

## Dispatching a task

```bash
scripts/spawn-repo-agent.sh --reply-lang Japanese <[owner/]repo> -- "<task>"
scripts/spawn-repo-agent.sh <[owner/]repo> -- "<task>"
scripts/spawn-repo-agent.sh --kind agy <owner>/<repo> -- "<task>"
scripts/spawn-repo-agent.sh --kind devin <owner>/<repo> -- "<task>"
scripts/spawn-repo-agent.sh --model opus --effort high <owner>/<repo> -- "<task>"
scripts/spawn-repo-agent.sh <[owner/]repo>          # spawn only — worker idles
scripts/spawn-repo-agent.sh --machine hw-a <[owner/]repo> -- "<task>"   # on another machine
```

**Another machine** — needs a plugin that provides machines
(`scripts/plugins.sh machines` lists them; e.g. `instances`). `--machine
<label>` (or its target) runs that machine's own `spawn-repo-agent.sh`
through the plugin, so the clone, the worktree, the Git credentials and
the worker stay on that machine. The plugin ensures the machine first (a
stopped container is restarted). Its output reports the pane as
`<label>/<pane>`; steer it with `herdr --machine <label> …`
(`herdr-control`). If the dispatch fails with `Action needed on <label>`,
the machine is a remote host the user must start — relay those steps
instead of retrying (the plugin's skill says how).

**Model and effort** — when the request names a model or an effort
level, pass it with `--model <model>` and/or `--effort <level>`; the
script maps them to each CLI's own flags (`claude`, `agy`, `codex`,
`pi`; `devin` takes `--model` only — its level is part of the model id,
e.g. `claude-opus-5-5-high`, so put a requested effort into the id).
They are independent: pass only what was specified —
don't ask for the other and don't invent defaults. Anything unspecified
is `inherit`: no flag is passed and the worker uses the CLI's own
settings.

Resolve names with `scripts/agent-models.sh` — never query the agent
CLIs (`agy models`, `codex debug models`, `pi --list-models`, …)
yourself; the script caches their answers:

```bash
scripts/agent-models.sh <kind>            # id <TAB> label <TAB> per-model efforts
scripts/agent-models.sh <kind> efforts    # kind-wide --effort values
scripts/agent-models.sh --refresh <kind>  # re-query (new model, stale list)
```

Map the user's words ("flash", "haiku 5.5", "qwen 35b") to an id from
that list. If several ids match and the request does not pick one (e.g.
agy's `gemini-3.8-flash-{high,medium,low}` or devin's
`claude-opus-5-5-{low,…,max}`), ask. The script rejects an
effort the chosen model does not support (per-model levels from codex's
catalog and pi's `thinkingLevelMap`).

The task is optional: omitting it spawns an idle worker in a fresh
worktree. The worker still gets a standby prompt carrying only the
self-naming contract — rename itself and its tab once a real task
arrives — so follow-up `herdr agent prompt <pane> "<task>"` keeps names
meaningful.

`spawn-repo-agent.sh` is the **only** entry point for other repos — it
goes all the way from worktree to a spawned, prompted agent. Never run
`create-worktree.sh` for another repo and stop there: a worktree with no
worker is a half-finished task. If inputs (task, kind, repo) are
missing, ask first — then dispatch once.

One call does the whole sequence:

1. `create-worktree.sh --detach` imports/refreshes `repos/<repo>` and
   creates `worktree/<repo>/task/<uuid>` on a **detached HEAD at
   `origin/main`** (`origin/master` when the repo has no main) — the uuid leaf keeps concurrent dispatches
   collision-free, and no branch is named before the task is understood.
   The worker names its own branch if and when it needs one; the
   orchestrator does not prescribe one.
2. `herdr workspace list` finds the workspace labeled `<repo>`; a new tab is
   added to it, or a new workspace is created — one workspace per repo, one
   tab per task.
3. The agent launches in that tab's root pane under a placeholder name
   `w-<uuid>` via `herdr agent start` (which falls back to `pane run` if
   the caller's permission classifier denies it). The worker runs
   unconfined.
4. `herdr agent prompt <pane> "<task>" --wait --until working --until blocked`
   submits the task atomically and returns once the worker picks it up,
   not when it finishes.
   The prompt embeds a short preamble telling the worker to rename itself
   (`herdr agent rename <pane> <slug>`) and its tab
   (`herdr tab rename <tab> <title>`) once it knows the task — names like
   `w-<repo>-<uuid>` mean nothing, so the worker picks a task slug itself.

The script prints `Dispatched to pane <pane_id> (repo=... worktree=...)` —
keep the `pane_id` for monitoring and follow-ups.

## After dispatch — report immediately

The script already waits for the agent to be ready and for the prompt to
be picked up. A clean `Dispatched to pane …` with no `Warning:` /
`Error:` / `Note:` line **is** the startup confirmation — report it to the user
right away.

- Do **not** `herdr agent wait` / `herdr agent read` after a clean
  dispatch to "make sure it started" or to see the worker's reply to the
  prompt. That waits on the worker's model turn and only adds latency.
- Inspect the pane **only** when the script printed a `Warning:`,
  `Error:` or `Note:` (a recovery step ran — e.g. a nudge or resend —
  so confirm what it actually answered), or when the user asks for
  status/output. Then read the whole recent screen once, not a grep for
  one marker, fix the cause, and report.
- Do not spawn extra workers to verify a dispatch; one dispatch per
  request.

## Talking to the user

Users act in natural language — never paste commands into your report
expecting the user to run them. You are the one who runs herdr; if the
user wants a task sent, a status check, or a worktree cleaned up, do it.
Only quote a command when the user explicitly asks how to do it
themselves.

Report the outcome and offer next steps as options, e.g.: "Worker
dispatched (pane `w2:p1`, worktree `worktree/R/task/<uuid>`). Send it a
task, or should it idle?" — not a `herdr agent prompt` snippet.

## Monitoring (pull model)

Workers are plain agents with no reporting protocol — they just go idle
when done. To find a worker from the user's description (task, repo,
name), and for focus, relays and interrupts, follow `herdr-control`:

```bash
herdr agent wait "<pane_id>" --until idle --until done --until blocked --timeout 600000
herdr agent read "<pane_id>" --source recent-unwrapped --lines 200
```

Send follow-up work to the same live agent with (a busy worker queues
it, and this returns at once; never use a bare `--wait`, which blocks
until the worker's turn ends — `herdr-control` "Relaying an
instruction"):

```bash
herdr agent prompt "<pane_id>" "<follow-up task>" --wait --until working --until blocked --timeout 15000
```

## Notes

- The worker inherits the repo's own conventions because its cwd is the
  worktree — those files must be committed in the repo to exist there.
- The script pre-trusts the worktree so the worker does not stop at a
  first-run confirmation prompt: it registers the path in agy's
  `trustedWorkspaces` and claude's `${CLAUDE_CONFIG_DIR:-~}/.claude.json` project trust list
  (also pre-answering "No" to the external CLAUDE.md imports dialog, so
  no `CLAUDE.md` outside the worktree is ever imported) and pi's
  `trust.json` (pi's trust check sees herdr-worktree's `.agents/skills`
  above the worktree; its skill discovery stops at the worktree root, so
  herdr-worktree's skills are never loaded);
  `devin` is launched with `--respect-workspace-trust false`.
- Each dispatch creates a fresh worktree; nothing is reused across tasks
  except the repo's herdr workspace itself.
- The worker starts as `w-<uuid>` and self-renames from the task prompt —
  if it skipped that step (or the rename failed), fall back to addressing
  it by pane id, which always works.
