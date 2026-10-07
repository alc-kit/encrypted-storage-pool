#!/usr/bin/env bash
#
# Device-free tests for the LVM backend's create path (brushup defects #1 and #9):
#   1. the caller's device order is checked BEFORE pvcreate/vgcreate — until v1.0.5 it
#      ran after them, so a refused order left a VG behind and every later run skipped
#      creation (the create block runs only when the VG is absent);
#   2. a VG present without its `data` LV (that half-built state) is refused by name;
#   3. an explicit member list is normalised to the bare UUID the backends prefix with
#      `crypt-` — the old deprecation message asked for `crypt-<uuid>`, which became
#      crypt-crypt-<uuid>.
#
# Usage: bash tests/create-order/run.sh   (from the repository root)
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd -P "$HERE/../.." >/dev/null 2>&1 && pwd)"
LVM="${LVM_FILE:-$ROOT/tasks/backends/lvm.yml}"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
command -v ansible-playbook >/dev/null 2>&1 || { echo "error: ansible-playbook not on PATH" >&2; exit 1; }

verdict="$(python3 - "$LVM" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
def walk(ts, out, depth=0):
    for t in ts or []:
        out.append(t)
        for k in ("block", "rescue", "always"):
            walk(t.get(k), out, depth + 1)
flat = []; walk(tasks, flat)
def cmd(t): return str(t.get("ansible.builtin.command", ""))
def inc(t): return str(t.get("ansible.builtin.include_tasks", ""))
i_order = next((i for i, t in enumerate(flat) if "lvm-device-order.yml" in inc(t)), None)
i_pv = next((i for i, t in enumerate(flat) if cmd(t).startswith("pvcreate")), None)
i_vg = next((i for i, t in enumerate(flat) if cmd(t).startswith("vgcreate")), None)
order_ok = None not in (i_order, i_pv, i_vg) and i_order < i_pv < i_vg
half = [t for t in flat if "ansible.builtin.assert" in t and "data_lv" in str(t)]
probe = [t for t in flat if cmd(t).strip().startswith("lvs ") and "/data" in cmd(t)]
half_ok = bool(half) and bool(probe) and all("vg_exists.rc == 0" in str(t.get("when", "")) for t in half + probe)
print("order=%s half=%s" % ("ok" if order_ok else "bad(%s,%s,%s)" % (i_order, i_pv, i_vg), "ok" if half_ok else "bad"))
PY
)"
case "$verdict" in *order=ok*) ok "the device order is checked before pvcreate and vgcreate" ;; *) bad "order: $verdict" ;; esac
case "$verdict" in *half=ok*) ok "a VG without its data LV is probed and refused, only when the VG exists" ;; *) bad "half-built: $verdict" ;; esac

got="$(ansible-playbook -i localhost, "$HERE/resolve-case.yml" \
        -e '{"encrypted_storage_pool_devices": ["1111-aaaa", "crypt-2222-bbbb", "/dev/mapper/crypt-3333-cccc"]}' 2>&1 \
       | grep -o 'RESOLVED=[^"]*' | head -n1)"
if [ "$got" = "RESOLVED=1111-aaaa,2222-bbbb,3333-cccc" ]; then
  ok "every spelling of an explicit member resolves to the bare UUID (no crypt-crypt-)"
else
  bad "explicit members resolved to [$got]"
fi

echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
