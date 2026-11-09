---
type: ADR
title: Sync instance labels both ways; the side that changed wins
description: The instances plugin records the label each instance had when the manifest and herdr last agreed, and on ensure/ls brings the side that did not change along; the manifest wins when both changed or nothing is recorded.
status: accepted
last_modified: 2026-11-06
tags: [plugin, multi-instance, labels]
---

# ADR-0020: Sync instance labels both ways; the side that changed wins

## Status

Accepted. Refines "a label renamed in herdr is adopted by the manifest"
(ADR-0014) for the instances plugin (ADR-0018).

## Context

`ensure` and `ls` copied herdr's machine label into the manifest and
never the other way. A label edited by hand in the manifest — the file
the plugin calls its source of truth — was silently overwritten by
herdr's old label on the next `ls` or `ensure`, and herdr kept showing
the old name.

## Decision

- The plugin records, per instance, the label the manifest and herdr last
  agreed on (`~/.config/herdr-worktree/labels.json`; `HW_LABELS_FILE`
  overrides).
- On `ensure` and `ls`, when the two differ: if the manifest still has
  the recorded label, herdr was renamed and the manifest takes herdr's
  label; otherwise the manifest was edited (or both were, or nothing is
  recorded) and herdr's machine is renamed to the manifest's label.
  Each change is reported on stderr.
- A manifest label herdr cannot take (invalid, or used by another
  machine) is reported; herdr keeps its label, nothing is recorded, and
  the manifest edit is not reverted.
- `rename`, a successful `ensure` and `rm` keep the record current.
  The contract's `machines` call only reads, so `list-workers.sh` shows
  herdr's label until the next `ensure` or `ls`.

## Consequences

- Editing the manifest, `instance rename` and renaming in herdr's TUI all
  end in the same label on both sides.
- A checkout that upgrades with no record yet treats the manifest as the
  truth once; a rename made only in herdr before the upgrade is undone.
