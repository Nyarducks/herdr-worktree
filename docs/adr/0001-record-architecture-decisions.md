---
type: ADR
title: Record architecture decisions
description: ADRs live in docs/adr/, numbered sequentially, with OKF v0.2 frontmatter.
status: accepted
last_modified: 2026-11-03
tags: [adr, process]
---

# ADR-0001: Record architecture decisions

## Status

Accepted

## Context

Design decisions recorded only in PR bodies and commit messages are hard
to discover and do not survive squashed history.

## Decision

Every significant architectural decision is recorded as an ADR under
`docs/adr/NNNN-<slug>.md`, numbered sequentially, written in
Context / Decision / Consequences form with OKF v0.2 YAML frontmatter
(`type: ADR`). Design docs live under `docs/design/` with the same
frontmatter convention. Both are updated in the same commit as the change
they describe. ADRs are point-in-time records: a revisited decision gets
a new ADR rather than an edit.

## Consequences

- Decisions are discoverable and reviewable alongside the code.
- Small documentation overhead per change; the rule lives in the
  `development` skill and `CONTRIBUTING.md`.
