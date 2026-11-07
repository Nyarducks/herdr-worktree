---
name: instances
description: Manage the machines the instances plugin provides — dev containers and remote hosts kept in its manifest — for the user: list them and their state, bring them back, rename, add a container or a host by IP, change a container's image, remove one, and relay what to start on a remote host. Use when the user asks about instances, containers, remote hosts or "machines" by name or label ("is hw-a up?", "call hw-a client-b", "add a container for X", "the box at 192.0.2.10").
---

# Instances (plugin)

The plugin's CLI is `plugins/instances/bin/instance` (every argument:
`--help`; the fields: `plugins/instances/instances.example.yml`). Each
instance has a fixed name and a label — what herdr shows, which the user
may change. Arguments take either.

| User intent | Do |
|---|---|
| Which instances are there / are they up? | `instance ls` (`name label kind address status registered image docker`), summarized |
| Bring them back | `instance ensure [<name-or-label>…]` |
| Rename one ("call hw-a client-b") | `instance rename <name-or-label> <new-label>` |
| Build an instance suited to a repository | follow the `instance-from-repo` skill (next to this one) |
| Use another image for a container | `instance image ls` / `image new <image>`; `--image` on `add container`, or change `image` in the manifest and `instance rebuild <name>` — a rebuild stops the container's agents, so confirm first |
| Add a container / a host by IP | `instance add container <name> [--docker]` / `add remote <name> <[user@]host> [--port] [--identity] [--dir]` — ask for anything the request leaves out |
| Smoke-check a container | `instance check <name-or-label>` |
| Remove one | `instance rm <name-or-label>` (`--purge` only when the user asks to delete a container's data, logins included) |

`list-workers.sh` and `spawn-repo-agent.sh --machine` already ensure a
machine that does not answer: a stopped container is restarted there and
then. A remote host is never started for the user. When `ensure` prints
`Action needed on <label>`, relay those steps to the user in their
language (what to start or install on which host), and run `instance
ensure <name>` again once they say it is done.

Logins inside an instance are the user's: never copy credentials in.
After a new container, tell them to log in there once (`gh auth login`,
the agent CLI).
