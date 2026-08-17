#!/usr/bin/env bash
#
# Device-free regression test for the pool topology + member-count guard
# (tasks/validate-topology.yml). Runs the REAL role task against synthetic
# topology / device-list values injected via fixtures/*.json and asserts that
# VALID setups pass and INVALID setups are REJECTED — no block devices, no root,
# no VMs. Runs on any CI runner.
#
# Each fixture supplies `encrypted_storage_pool_topology` and
# `encrypted_storage_pool_devices_resolved`; the pass/fail expectation lives in
# this script (see the expect calls below).
#
# Usage: tests/topology/run.sh   (exits non-zero on any unexpected result)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX="$HERE/fixtures"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "error: ansible-playbook not on PATH" >&2
  exit 1
fi

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# expect <fixture> <ok|fail>: run the guard against fixtures/<fixture>.json and
# check the play exit status matches the expectation.
expect() {
  local fixture="$1" want="$2" got
  ansible-playbook -i 'localhost,' -c local \
    "$HERE/assert-fixtures.yml" -e "@$FIX/$fixture.json" >/dev/null 2>&1
  got=$?
  if { [ "$want" = ok ] && [ "$got" -eq 0 ]; } || \
     { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
    ok "topology $fixture -> rc $got (expected $want)"
  else
    bad "topology $fixture -> rc $got (expected $want); re-run without -q:"
    echo "     ansible-playbook -i localhost, -c local $HERE/assert-fixtures.yml -e @$FIX/$fixture.json"
  fi
}

# ── Valid setups: the guard must PASS ─────────────────────────────────────────
expect valid-mirror     ok    # mirror, 2 disks
expect valid-stripe     ok    # stripe, 2 disks
expect valid-raid10-4   ok    # raid10, 4 disks (minimum)
expect valid-raid10-10  ok    # raid10, 10 disks (the multi-disk target)

# ── Invalid setups: the guard must REJECT ─────────────────────────────────────
expect invalid-mirror-one   fail   # mirror with 1 disk   (< 2)
expect invalid-stripe-one   fail   # stripe with 1 disk   (< 2)
expect invalid-raid10-two   fail   # raid10 with 2 disks  (< 4)
expect invalid-raid10-odd   fail   # raid10 with 5 disks  (odd count)
expect invalid-topology     fail   # unknown topology name

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
