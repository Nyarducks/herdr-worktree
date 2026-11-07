---
type: ADR
title: Keep an instance's logins in one state volume, with a list of persisted paths
description: Instead of one compose volume per tool, each instance has one state volume at ~/.persist; the entrypoint links every path listed in docker/<image>/persist (and the instance's own ~/.persist/persist.list) into it.
status: accepted
last_modified: 2026-11-06
tags: [container, credentials, multi-instance]
---

# ADR-0016: Keep an instance's logins in one state volume, with a list of persisted paths

## Status

Accepted

## Context

Logins happen inside each instance and must survive rebuilds (ADR-0013),
and are never copied in from elsewhere. Each tool keeps them in its own
place — `gh` and herdr in `~/.config`, Claude Code in `~/.claude`, Codex
in `~/.codex`, and so on. With one compose volume per place, adding an
agent CLI meant editing `compose.yml` for every instance, and an
instance's credentials were spread over several volumes.

## Decision

- Each instance has one volume, `state`, mounted at `~/.persist`.
- `docker/<image>/persist` lists home-relative paths (default: `.config`,
  `.claude`, `.codex`, `.gemini`, `.pi`). At every container start the
  entrypoint makes each a symlink into the volume — on first use it moves
  what the image put there, afterwards the volume's copy wins.
- An instance can add paths without a rebuild in
  `~/.persist/persist.list` (applied on the next start).
- `CLAUDE_CONFIG_DIR` stays `~/.claude`, so Claude Code's `.claude.json`
  lives in that directory, not as a lone file in the home directory.

## Consequences

- A new CLI needs one line, not a volume; paths no tool uses yet cost
  nothing.
- All credentials of an instance are deleted together with its volume
  (`down --purge`).
- Instances created before this change keep their logins in the old
  `config` and `claude` volumes, which the new compose file no longer
  mounts: after a recreate the user logs in again (logins are not moved
  between volumes), and the old volumes can then be removed.
- Custom images must copy `persist` and the entrypoint as the default
  image does.
