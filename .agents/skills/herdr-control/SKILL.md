---
name: herdr-control
description: Operate herdr for the user and steer running workers from natural-language requests — move to a worker's pane or tab, relay an instruction to the worker that owns a task, check status, interrupt, or close a finished worker. Use whenever the user refers to a worker, a pane/tab, or a dispatched task ("go to the DB role worker", "tell the billing worker to also add tests", "how are the workers doing?"). New dispatches go through worktree-development.
---

# herdr control (steering workers)

The orchestrator runs herdr for the user. The user speaks in natural
language about workers and tasks; turn that into herdr operations and
report the outcome in natural language — never hand the user a command
to run unless they ask how to do it by hand. Starting a new worker is
`worktree-development`; this skill covers everything after that.

## Language

- Think in English.
- Reply to the user in the user's natural language (the language of
  their latest message).
- Write prompts to workers in English, and keep the reply-language rule
  in force: workers were told at dispatch to reply in the user's
  language (`spawn-repo-agent.sh --reply-lang`). When relaying an
  instruction, translate its intent into English but keep quoted text,
  identifiers, error messages and file names verbatim. If the user
  switched languages since dispatch, append
  `Reply in <language> from now on.` to the relayed prompt.

## Precondition

```bash
[[ "${HERDR_ENV:-}" == "1" ]] && command -v herdr >/dev/null
```

If this fails, tell the user herdr isn't available.

## Resolve the target worker first

Every operation needs one pane id. Resolve the user's words to it:

```bash
scripts/list-workers.sh                 # all dispatched workers
scripts/list-workers.sh <word> [word…]  # rows containing every word
```

Columns (tab-separated): `pane_id name repo status tab_label title`.
`name` is the worker's self-chosen slug, `title` its terminal title (the
task summary), `repo` the repository. Match on any of them — a task
description ("the DB role one"), a repository ("the billing worker"), a
slug, a tab label, or a pane id the user quotes.

- **Exactly one row** → use its `pane_id`.
- **Several rows** → ask the user which one (ask-question tool:
  `AskUserQuestion` / `ask_user_question` / `ask_question`), offering each
  row as `name — title (repo, status)`. Never guess.
- **No row** → say so, and show the current list in natural language. If
  the user meant new work, offer to dispatch via `worktree-development`.

Only workers in task worktrees are listed; the orchestrator's own pane
and other agents are excluded on purpose.

## Operations

| User intent | Do |
|---|---|
| Move to / show a worker ("go to", "open", "switch to") | `herdr agent focus <pane_id>` |
| Move to a tab | `herdr tab focus <tab_id>` (tab ids: `herdr tab list`) |
| Send an instruction to a worker / task | relay (below) |
| Status of one worker | `herdr agent get <pane_id>` for the state; `herdr agent read <pane_id> --source recent-unwrapped --lines 200` for what it is doing — summarize, don't paste |
| Status of all workers | `scripts/list-workers.sh`, summarized per worker (name, repo, state, task) |
| Wait for a worker to finish | `herdr agent wait <pane_id> --until idle --until blocked --timeout <ms>` |
| Interrupt a worker ("stop", "cancel that") | `herdr pane send-keys <pane_id> esc`, then confirm the state |
| Close a finished worker | only after the user approves cleanup — see `orchestration.md` "Ownership and cleanup" |

Focus changes what the user's terminal shows; do it only when asked.

## Relaying an instruction

1. Resolve the pane (above) and check its state with `herdr agent get`.
2. By state:
   - `idle` / `done` → send it.
   - `working` → ask the user whether to queue it (wait for idle, then
     send) or interrupt now (`esc`, then send). Pasting into a busy
     agent interleaves contexts.
   - `blocked` → the worker is waiting on a permission or question. Read
     the screen, tell the user what it is asking, and let the user
     decide; never answer a permission dialog on your own.
3. Send:

   ```bash
   herdr agent prompt <pane_id> "<English instruction>" --wait --until working --until blocked --timeout 120000
   ```

4. Report "sent to <name> (<repo>)" right away. Do not wait for the
   worker's answer unless the user asked for it; read the result later
   when asked.

One instruction goes to one worker. If the request names several
("tell every billing worker to rebase"), resolve each, list them back,
and send to each in turn.

## Notes

- The pane id always works; agent names change when a worker renames
  itself, so re-resolve instead of caching names across turns.
- The user may also type into a worker's pane directly. Avoid prompting
  a worker the user is typing into — ask first if unsure.
- Never edit a worker's worktree yourself (`development` rule 3).
