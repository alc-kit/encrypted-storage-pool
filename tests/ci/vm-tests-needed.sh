#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Decide whether the nested-KVM molecule scenarios need to run for this change.
# Prints `true` or `false`; reasoning goes to stderr.
#
# DENY BY DEFAULT — the question is "is EVERY changed file provably inert?", not
# "did a relevant file change?". A relevant-path list goes stale the moment someone
# adds a directory nobody thought about; an inert list fails safe.
#
# This replaces a `paths:` filter on the workflow, which was actively harmful:
# `molecule vm (btrfs, libvirt/KVM)` and `molecule vm (lvm, libvirt/KVM)` are
# REQUIRED checks on main, and a workflow skipped by path filtering never reports
# its checks — so a PR touching only README.md, meta/, files/ or scripts/ would wait
# forever on checks that can never arrive. The workflow now always runs and always
# reports; only the expensive steps are gated.
#
#   tests/ci/vm-tests-needed.sh [<base-ref>]
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
say() { printf '%s\n' "$*" >&2; }

# Only what cannot change what the scenarios build or assert. Note what is NOT here:
# tasks/, templates/, defaults/, handlers/, molecule/, files/, meta/, scripts/,
# tests/, requirements.yml.
INERT_RE='^(.*\.md$|\.gitignore$)'

BASE="${1:-${GITHUB_BASE_REF:-}}"
if [ -z "$BASE" ]; then
  say "no base ref (not a pull request?) — running the VM tests"; echo true; exit 0
fi

BASE_REF=""
for cand in "origin/$BASE" "$BASE"; do
  if git rev-parse --verify --quiet "$cand" >/dev/null; then BASE_REF="$cand"; break; fi
done
if [ -z "$BASE_REF" ]; then
  say "base ref '$BASE' does not resolve — running the VM tests (fail safe)"; echo true; exit 0
fi

MB="$(git merge-base "$BASE_REF" HEAD 2>/dev/null)"
if [ -z "$MB" ]; then
  say "no merge base with '$BASE_REF' — running the VM tests (fail safe)"; echo true; exit 0
fi

CHANGED="$(git diff --name-only "$MB" HEAD)"
if [ -z "$CHANGED" ]; then
  say "no files changed — running the VM tests (fail safe)"; echo true; exit 0
fi

RELEVANT="$(printf '%s\n' "$CHANGED" | grep -vE "$INERT_RE" || true)"
say "changed files ($(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')):"
printf '%s\n' "$CHANGED" | sed 's/^/  /' >&2
if [ -z "$RELEVANT" ]; then
  say ""; say "every changed file is inert (markdown, .gitignore) — SKIPPING the VM tests."
  echo false
else
  say ""; say "these are NOT provably inert — running the VM tests:"
  printf '%s\n' "$RELEVANT" | sed 's/^/  /' >&2
  echo true
fi
