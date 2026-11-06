---
type: ADR
title: Support macOS with portable locking and BSD-safe tooling
description: Scripts run on Linux and macOS — mkdir lockdirs instead of flock, BSD-compatible mktemp templates, bash ≥ 4.3 from Homebrew on macOS, and a macOS CI job.
status: accepted
last_modified: 2026-11-03
tags: [macos, portability]
---

# ADR-0011: Support macOS with portable locking and BSD-safe tooling

## Status

Accepted

## Context

The scripts were written against GNU/Linux. On macOS, `flock(1)` does
not exist (it was used to serialize agent-settings merges), BSD `mktemp`
requires its `X`s at the end of the template, and `/bin/bash` is 3.2.

## Decision

- `json_merge_atomic` locks with `mkdir <file>.lock.d` — `mkdir(2)` is
  atomic everywhere — and reclaims a stale lock after about 10s.
- `mktemp` templates keep their `X`s trailing.
- bash ≥ 4.3 is a documented requirement; on macOS it comes from
  Homebrew.
- CI runs the same suites on `macos-latest` with Homebrew bash and jq.

## Consequences

- No dependency beyond the documented requirements on either OS.
- A merge holder killed mid-merge leaves an empty lockdir that the next
  caller reclaims after the timeout.
