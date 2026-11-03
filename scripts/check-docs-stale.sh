#!/usr/bin/env bash
# check-docs-stale.sh — enforce the docs freshness contract.
#
# Every doc under docs/design/ and docs/reference/ declares the files it
# is derived from in its `sources:` frontmatter. This script fails when:
#
#   MISSING  a declared source path no longer exists (renamed/deleted)
#   STALE    a source changed in <base>...HEAD but the doc did not
#
# docs/adr/ is excluded on purpose — ADRs are point-in-time records and
# are never updated for code drift; a revisited decision gets a new ADR.
#
# Usage: check-docs-stale.sh [base-ref]   (default: origin/main)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base="${1:-origin/main}"
merge_base="$(git merge-base "${base}" HEAD)"
changed="$(git diff --name-only "${merge_base}" HEAD)"

# Print the `sources:` entries of doc $1, one per line. Only the
# flow-style form `sources: [a, b]` is supported — keep entries inline.
extract_sources() {
  local line
  line="$(sed -n '2,/^---$/p' "$1" | grep -m1 '^sources:' || true)"
  [[ "${line}" =~ \[(.*)\] ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}" | tr ',' '\n' | sed 's/^ *//; s/ *$//; /^$/d'
}

status=0
for doc in docs/design/*.md docs/reference/*.md; do
  [[ -f "${doc}" ]] || continue
  sources="$(extract_sources "${doc}")"
  [[ -n "${sources}" ]] || continue

  # Integrity: declared sources must still exist.
  while IFS= read -r src; do
    if [[ ! -e "${src}" ]]; then
      printf 'MISSING  %s — source %s no longer exists\n' "${doc}" "${src}"
      status=1
    fi
  done <<< "${sources}"

  # Freshness: a changed source implies the doc changed in the same diff.
  touched=""
  while IFS= read -r src; do
    [[ -e "${src}" ]] || continue
    if [[ -d "${src}" ]]; then
      hit="$(printf '%s\n' "${changed}" | grep -F "${src}/" || true)"
    else
      hit="$(printf '%s\n' "${changed}" | grep -xF "${src}" || true)"
    fi
    [[ -n "${hit}" ]] && touched="${touched} ${src}"
  done <<< "${sources}"
  if [[ -n "${touched}" ]] && ! grep -qxF "${doc}" <<< "${changed}"; then
    printf 'STALE    %s — sources changed without a doc update:%s\n' "${doc}" "${touched}"
    status=1
  fi
done

if [[ "${status}" -eq 0 ]]; then
  echo "docs fresh: declared sources exist and none changed without its doc"
else
  echo "" >&2
  echo "Update the flagged doc in the same PR — or fix its sources: if the" >&2
  echo "path is not really a source of truth for it. See CONTRIBUTING.md." >&2
fi
exit "${status}"
