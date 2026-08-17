#!/usr/bin/env bash
#
# Run an encrypted_storage_pool Molecule VM scenario locally.
#
# Why this wrapper exists
# -----------------------
# The scenario needs two environment variables that the tooling does NOT set
# for you; forget either and molecule fails in confusing ways:
#
#   ANSIBLE_LIBRARY      molecule-core >= 25.12 no longer auto-adds the Vagrant
#                        driver's bundled `vagrant` module to ANSIBLE_LIBRARY.
#                        Without it every step dies on
#                        "couldn't resolve module/action 'vagrant'".
#   LIBVIRT_DEFAULT_URI  vagrant-libvirt defaults to a session URI that can't
#                        hand out the DHCP lease Vagrant needs to find the guest
#                        IP; the scenario forces system libvirt (qemu:///system).
#
# This script wires both, then hands off to molecule. It works from any cwd.
# Scenarios: 'vm' (default, 4-disk mirror) and 'raid10' (10-disk raid10; lvm
# variant builds a thin pool). CI runs each for both backends (btrfs + lvm) via a
# matrix — locally the backend defaults to btrfs unless $ESP_BACKEND is set.
#
# Usage
# -----
#   ./scripts/run.sh                 # full lifecycle: molecule test -s vm
#   ./scripts/run.sh converge        # molecule converge -s vm  (iterate)
#   ./scripts/run.sh verify          # molecule verify -s vm
#   ./scripts/run.sh destroy         # molecule destroy -s vm   (clean up)
#   ./scripts/run.sh login           # extra args pass through to molecule
#
#   MOLECULE_SCENARIO=raid10 ./scripts/run.sh   # pick the scenario (default: vm)
#   ESP_BACKEND=lvm ./scripts/run.sh            # pick the backend  (default: btrfs)
#
# Prerequisites (see README.md → Testing): libvirt + KVM + Vagrant +
# vagrant-libvirt, your user in the `libvirt` group, nested virt enabled, and
# molecule with the vagrant plugin (`pip install 'molecule-plugins[vagrant]'`).
set -euo pipefail

# Resolve this script's dir (following symlinks) so the role dir is unambiguous.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
ROLE_DIR="$(dirname "$SCRIPT_DIR")"

SCENARIO="${MOLECULE_SCENARIO:-vm}"
SUBCMD="test"
if [ "$#" -gt 0 ]; then
  SUBCMD="$1"
  shift
fi

# --- Preflight: molecule present -------------------------------------------
if ! command -v molecule >/dev/null 2>&1; then
  echo "error: 'molecule' not found on PATH." >&2
  echo "       pip install molecule 'molecule-plugins[vagrant]' python-vagrant ansible" >&2
  exit 1
fi

# --- ANSIBLE_LIBRARY: point at the Vagrant driver's bundled module ----------
# Computed from the installed package so it's portable across install locations
# (system site-packages, ~/.local, a venv, ...).
if ! ANSIBLE_LIBRARY="$(python3 -c 'import molecule_plugins.vagrant, os; print(os.path.join(os.path.dirname(molecule_plugins.vagrant.__file__), "modules"))' 2>/dev/null)"; then
  echo "error: could not import molecule_plugins.vagrant." >&2
  echo "       The Vagrant driver is missing: pip install 'molecule-plugins[vagrant]'" >&2
  exit 1
fi
export ANSIBLE_LIBRARY

# --- LIBVIRT_DEFAULT_URI: system libvirt (respect an explicit override) -----
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

echo "==> role scenario : ${SCENARIO}"
echo "==> molecule cmd  : molecule ${SUBCMD} -s ${SCENARIO} $*"
echo "==> ANSIBLE_LIBRARY=${ANSIBLE_LIBRARY}"
echo "==> LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI}"
echo

cd "$ROLE_DIR"
exec molecule "$SUBCMD" -s "$SCENARIO" "$@"
