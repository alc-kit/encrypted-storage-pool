#!/usr/bin/env bash
#
# Device-free regression test for the redundancy-coverage gate
# (files/encrypted-storage-redundancy-check), which decides whether a VG with
# missing PVs may be activated with `vgchange --activationmode partial`.
#
# Drives the REAL production script — the same bytes deployed to
# /usr/local/sbin/encrypted-storage-redundancy-check — via its --from-file mode,
# against `lvs -a -o lv_name,segtype,devices` output CAPTURED FROM A LIVE LVM
# under each disk-loss shape. No LVM, no root, no block devices, no VMs.
#
# Fixture provenance: every fixtures/*.lvs file except the two named
# `synthetic-*` was captured verbatim from a real raid10 thin pool with real
# devices removed (see the work package's §7.8 probe harness), so the parser is
# tested against LVM's actual output format rather than an idealised one. The two
# synthetic fixtures are hand-derived from a captured one to reach shapes this
# role cannot currently build (a lost pmspare in isolation; an unsupported raid
# level) and are marked as such.
#
# Usage: tests/redundancy/run.sh   (exits non-zero on any unexpected result)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX="$HERE/fixtures"
CHECK="$HERE/../../files/encrypted-storage-redundancy-check"

[ -x "$CHECK" ] || { echo "error: $CHECK is missing or not executable" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# expect <fixture> <covered|blocked> <why>
expect() {
  local fixture="$1" want="$2" why="$3" got out
  out=$("$CHECK" --from-file "$FIX/$fixture.lvs" 2>&1)
  got=$?
  if { [ "$want" = covered ] && [ "$got" -eq 0 ]; } || \
     { [ "$want" = blocked ] && [ "$got" -eq 1 ]; }; then
    ok "$fixture -> $want ($why)"
  else
    bad "$fixture -> rc $got, expected $want ($why)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

# ── Redundancy covers the loss: partial activation is SAFE ────────────────────
expect healthy                    covered "nothing missing"
expect raid10-4-single-lost       covered "one disk of four; its mirror partner survives"
expect raid10-4-crosspair-lost    covered "two disks, in DIFFERENT mirror pairs"
expect raid10-10-oneperpair-lost  covered "five of ten disks, exactly one per mirror pair"
expect meta-raid1-oneleg-lost     covered "one leg of the mirrored thin-pool metadata"
expect synthetic-pmspare-only-lost covered "only the repair-time spare metadata copy (synthetic)"

# ── Redundancy does NOT cover it: activation must be REFUSED ──────────────────
expect raid10-4-samepair-lost     blocked "both members of one mirror pair"
expect raid10-10-samepair-lost    blocked "both members of one mirror pair, wide pool"
expect meta-raid1-bothlegs-lost   blocked "both legs of the mirrored metadata"
expect meta-linear-lost           blocked "linear (unmirrored) thin-pool metadata — the default layout's SPOF"
expect synthetic-raid5-unsupported blocked "raid level this role never builds; refuse to guess (synthetic)"

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
