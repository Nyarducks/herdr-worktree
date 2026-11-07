---
type: ADR
title: Link an enabled plugin's skills into .agents/skills
description: Enabling a plugin links each skill its describe names as .agents/skills/plugin-<id>-<name>, so agents discover them like core's skills; a name clash refuses the enable.
status: accepted
last_modified: 2026-11-06
tags: [plugin, skills]
---

# ADR-0019: Link an enabled plugin's skills into .agents/skills

## Status

Accepted. Refines the "core's skills only point to the skills a plugin
describes" part of ADR-0018.

## Context

ADR-0018 left a plugin's skills inside the plugin; `herdr-control` only
told the orchestrator to read the skills `hw-plugin describe` names. Tried
with natural-language requests to a fresh Claude Code orchestrator ("is
the <instance> up?", "list the machines and tell me how to rename
one"), the orchestrator never loaded `herdr-control` or ran `describe` for
them: those requests are about machines, not workers, so nothing pointed
it there. It found the plugin by searching the checkout, read the
README or the skill only when a search happened to hit it, and answered
from the manifest without checking the state. Agents list skills from
`.agents/skills` (`.claude/skills` links to it, ADR-0005) by their
descriptions; a plugin's skill outside it is invisible to that listing.

## Decision

- `scripts/plugins.sh enable` links each skill directory `describe` names
  as `.agents/skills/plugin-<id>-<name>` (`<name>` from the skill's
  `SKILL.md` frontmatter). The links are git-ignored
  (`.agents/skills/plugin-*`). `disable` removes them with the plugin
  link.
- A described skill without `SKILL.md`, or whose name a skill not from the
  same plugin already uses, refuses the enable before anything is linked.
- `describe`'s `skills` may be absolute or relative to the plugin
  directory (still contract 1).
- `herdr-control` names the listed skill instead of a path to read.

## Consequences

- An enabled plugin's skills trigger from their own descriptions, the same
  way core's do; disabling the plugin removes them from the listing.
- Checkouts that enabled a plugin before this change must run `enable`
  again to get the links.
- The link directory names are prefixed, so the git-ignore pattern cannot
  hide a core skill; a core skill must not be named `plugin-*`.
