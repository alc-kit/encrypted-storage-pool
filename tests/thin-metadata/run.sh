#!/usr/bin/env bash
#
# Device-free regression test for the thin-pool metadata redundancy decision
# (tasks/backends/lvm-thin-metadata-plan.yml): is the metadata LV linear (a
# single-disk point of failure for the whole pool) and, if so, which PV should the
# second raid1 leg land on?
#
# Runs the REAL task file against `lvs -a -o lv_name,segtype,devices` output CAPTURED
# FROM A LIVE thin pool — before mirroring, after mirroring, and from a VG with no
# thin pool at all. No LVM, no root, no block devices, no VMs.
#
# Usage: tests/thin-metadata/run.sh   (exits non-zero on any unexpected result)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

command -v ansible-playbook >/dev/null 2>&1 || { echo "error: ansible-playbook not on PATH" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# case <label> <ok|fail> <extra-vars-json>
case_run() {
  local label="$1" want="$2" json="$3" got
  ansible-playbook -i 'localhost,' -c local "$HERE/assert-fixtures.yml" -e "$json" >/dev/null 2>&1
  got=$?
  if { [ "$want" = ok ] && [ "$got" -eq 0 ]; } || { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
    ok "$label"
  else
    bad "$label (rc $got, expected $want); re-run to see why:"
    echo "     ansible-playbook -i localhost, -c local $HERE/assert-fixtures.yml -e '$json'"
  fi
}

# ── Linear metadata: the pool is exposed, so it must be mirrored ───────────────
case_run "linear metadata, no candidates -> mirror it, let LVM place the leg" ok \
  '{"lvs_fixture":"linear-metadata.lvs","expect_needed":true,"expect_target":""}'

case_run "linear metadata + candidates -> target the first free candidate" ok \
  '{"lvs_fixture":"linear-metadata.lvs","encrypted_storage_pool_lvm_thin_meta_devices":["/dev/loop3","/dev/loop4"],"expect_needed":true,"expect_target":"/dev/loop3"}'

# /dev/loop0 already carries the linear metadata in the fixture, so it must be skipped
# in favour of the next candidate — raid1 legs cannot share a PV.
case_run "candidate already holding the metadata is skipped, not chosen" ok \
  '{"lvs_fixture":"linear-metadata.lvs","encrypted_storage_pool_lvm_thin_meta_devices":["/dev/loop0","/dev/loop5"],"expect_needed":true,"expect_target":"/dev/loop5"}'

# Bare crypt-<uuid> member names are the role's usual currency and must be mapped to
# /dev/mapper/crypt-<uuid> before they reach lvconvert.
case_run "bare crypt-<uuid> member name is mapped to a PV path" ok \
  '{"lvs_fixture":"linear-metadata.lvs","encrypted_storage_pool_lvm_thin_meta_devices":["1234-abcd"],"expect_needed":true,"expect_target":"/dev/mapper/crypt-1234-abcd"}'

# ── Already mirrored: nothing to do (idempotence) ─────────────────────────────
case_run "raid1 metadata -> no action (idempotent re-converge)" ok \
  '{"lvs_fixture":"mirrored-metadata.lvs","expect_needed":false,"expect_target":""}'

# ── No thin pool present: must not act, must not crash ────────────────────────
case_run "VG with no thin pool -> no action, no error" ok \
  '{"lvs_fixture":"no-thin-pool.lvs","expect_needed":false,"expect_target":""}'

# ── Caller error: the ONLY candidate is the PV already in use -> must FAIL ─────
case_run "only candidate is the PV already holding the metadata -> fail loudly" fail \
  '{"lvs_fixture":"linear-metadata.lvs","encrypted_storage_pool_lvm_thin_meta_devices":["/dev/loop0"],"expect_needed":true,"expect_target":""}'

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
