#!/usr/bin/env bash
#
# Device-free regression test for the explicit PV-order preparation
# (tasks/backends/lvm-device-order.yml), which is what pins raid image placement —
# and therefore which two disks form a mirror pair — when a caller supplies an
# order it computed from the hardware topology.
#
# Runs the real task file against synthetic member lists. No LVM, no devices, no
# root, no VMs.
#
# Usage: tests/device-order/run.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX="$HERE/fixtures"

command -v ansible-playbook >/dev/null 2>&1 || { echo "error: ansible-playbook not on PATH" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# expect <fixture> <ok|fail> <why>
expect() {
  local fixture="$1" want="$2" why="$3" got
  ansible-playbook -i 'localhost,' -c local "$HERE/assert-fixtures.yml" \
    -e "@$FIX/$fixture.json" >/dev/null 2>&1
  got=$?
  if { [ "$want" = ok ] && [ "$got" -eq 0 ]; } || \
     { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
    ok "$fixture — $why"
  else
    bad "$fixture — $why (rc $got, expected $want); re-run to see it:"
    echo "     ansible-playbook -i localhost, -c local $HERE/assert-fixtures.yml -e @$FIX/$fixture.json"
  fi
}

# ── Accepted spellings: all three must yield the same PV paths ────────────────
expect bare-names   ok "bare crypttab names (what resolve-disks.yml produces)"
expect full-paths   ok "full /dev/mapper paths (what a topology-aware caller passes)"
expect mapper-names ok "crypt-<uuid> mapper names are NOT double-prefixed"
expect no-order     ok "no order -> empty PV list -> lvcreate behaves as before"

# ── Refusals: an order that does not name exactly the members ─────────────────
# Each of these would otherwise place raid images on devices the caller did not
# choose, while still looking deliberate.
expect missing-member   fail "an order missing a member is refused, not padded"
expect foreign-member   fail "an order naming a non-member is refused"
expect duplicate-member fail "a duplicated member is refused (it hides a missing one)"

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
