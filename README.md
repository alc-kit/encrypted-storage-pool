# encrypted_storage_pool

A generic storage-pool consumer for LUKS devices unlocked by
[`clevis_encryption`](https://github.com/alc-kit/clevis-encryption-role). It
assembles a **btrfs** or **LVM** pool on the `crypt-*` mappers, consumes
`clevis-luks-unlocked.target`, and emits `encrypted-storage-ready.target`.

It is the **filesystem-agnostic, non-ZFS** counterpart of proxmox-install's
`proxmox_encrypted_storage` role — same seam contract, mainline filesystems (no
DKMS). Its first job is to give `clevis_encryption`'s own test harness a real
downstream consumer to validate boot-time unlock + ordering without pulling ZFS
into clevis's CI.

## Where it fits

```
clevis_encryption  (NBDE)            LUKS2 + Clevis/Tang; opens crypt-* mappers
   └─ publishes  clevis-luks-unlocked.target   ← the seam (unlock has run)
        │
        ▼
encrypted_storage_pool  (this role)
   btrfs mkfs / LVM vgcreate → mount → write-probe check
   └─ publishes  encrypted-storage-ready.target  ← the barrier
```

## Boot chain

```
clevis-luks-unlocked.target             (from clevis_encryption)
  → encrypted-storage-assemble.service   btrfs device scan / vgchange -ay, then mount
  → encrypted-storage-check.service      mounted + writable → ok, else exit 1
  → encrypted-storage-ready.target       synchronization barrier (WantedBy=multi-user)
```

The filesystem's fstab entry is **noauto** so the early `local-fs` chain never
touches it — this late, network-ordered `assemble` unit owns the mount, avoiding
the systemd ordering cycle that ordering a filesystem after a network-bound unlock
would otherwise create.

`assemble` orders `Wants=`/`After=` the seam (not `Requires=`): the unlock is
fail-degraded, and fail-**closed** lives in the `check → ready` `Requires=` chain
(a partial unlock can still bring up a `-o degraded` btrfs raid1; the check gate
decides viability).

## Backends

| `encrypted_storage_pool_backend` | create | `mirror` | `stripe` | `raid10` |
|---|---|---|---|---|
| `btrfs` | `mkfs.btrfs` across the mappers | `-d raid1 -m raid1` | `-d single -m single` | `-d raid10 -m raid10` |
| `lvm` | pvcreate + vgcreate + lvcreate + `mkfs.ext4` | `--type raid1 -m1` | `--type striped -i N` | `--type raid10 -i N/2` |

`raid10` is a stripe over 2-way mirrored pairs and requires **≥4 member disks and
an even count** (validated up front by `tasks/validate-topology.yml`, which also
enforces `mirror`/`stripe` ≥2 and rejects unknown topology names before any
destructive `mkfs`/`lvcreate`). `mirror`/`stripe` require ≥2.

### LVM thin provisioning

Set `encrypted_storage_pool_lvm_thin: true` (lvm backend only) to build a **thin
pool** whose data LV carries the chosen topology's RAID geometry (e.g. raid10),
plus a thin `data` volume on top — the mount source stays `/dev/<vg>/data`, so it
is a drop-in for the thick path. `thin-provisioning-tools` is installed
automatically. The btrfs backend ignores the thin variables.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `encrypted_storage_pool_enabled` | `true` | Set `false` to make the role a no-op. |
| `encrypted_storage_pool_backend` | `btrfs` | `btrfs` or `lvm`. |
| `encrypted_storage_pool_name` | `data` | btrfs LABEL / LVM volume-group name. |
| `encrypted_storage_pool_topology` | `mirror` | `mirror`, `stripe`, or `raid10` (raid10 needs ≥4 even disks). |
| `encrypted_storage_pool_mountpoint` | `/srv/{{ name }}` | Mount point (fstab noauto). |
| `encrypted_storage_pool_devices` | *(derived)* | Bare disk names (e.g. `[vdb, vdc]`). Unset → derived from `crypt-*` in `/etc/crypttab`. |
| `encrypted_storage_pool_ensure` | `true` | Create/assemble the pool on every run. |
| `encrypted_storage_pool_install_packages` | `true` | Install `btrfs-progs` / `lvm2` (+ `thin-provisioning-tools` when thin). |
| `encrypted_storage_pool_destroy_existing` | `false` | **Destructive.** Destroy an existing pool first. |
| `encrypted_storage_pool_lvm_thin` | `false` | lvm backend: build a thin pool + thin volume (see below). |
| `encrypted_storage_pool_lvm_thin_pool_extents` | `95%FREE` | Extents for the thin pool data LV (leaves VG headroom for metadata). |
| `encrypted_storage_pool_lvm_thin_pool_name` | `tpool` | Thin pool LV name (the volume stays `data`). |
| `encrypted_storage_pool_lvm_thin_virtual_size` | *(match pool)* | Thin volume virtual size; empty → 1:1 with the pool. |

## Usage

Runs after `clevis_encryption` (NBDE-only). Requires `clevis_encryption` **>= v1.2.0**
(publishes `clevis-luks-unlocked.target` + supports `clevis_deploy_storage_units`).

```yaml
roles:
  - role: clevis_encryption
    clevis_ensure_pool: false
    clevis_install_zfs_packages: false
    clevis_deploy_storage_units: false
  - role: encrypted_storage_pool
    encrypted_storage_pool_backend: btrfs   # or lvm
    encrypted_storage_pool_topology: mirror
```

## Testing

**Device-free (tier-0, no VMs).** `tests/topology/run.sh` runs the real
`validate-topology.yml` guard against synthetic fixtures and asserts that valid
setups pass and invalid ones (unknown topology, too-few members, odd raid10) are
rejected. Wired into the `CI` workflow next to yamllint/ansible-lint.

**VM boot tests (tier-2, nested KVM).** Molecule scenarios boot two VMs — an
external Tang server and an encrypted target — apply `clevis_encryption`
(NBDE-only) + this role, **reboot**, and assert the real cross-role boot chain:
mappers open under `crypt-<uuid>`, `clevis-luks-unlocked.target` reached, seam
ordering held (`unlock ≤ unlocked.target ≤ assemble`), pool mounted, real I/O
round-trips, and a payload written pre-reboot survives byte-for-bit.

| scenario | disks | topology | notes |
|---|---|---|---|
| `vm` | 4 × 2 GiB | `mirror` | the baseline boot test |
| `raid10` | 10 × 1 GiB | `raid10` | multi-disk; lvm variant builds a raid10 **thin pool** |

The `vm-tests` CI workflow matrixes **both scenarios × both backends** (btrfs +
lvm). Run locally with `./scripts/run.sh` (`vm`) or
`MOLECULE_SCENARIO=raid10 ./scripts/run.sh`; pick the backend with `ESP_BACKEND`. No
DKMS — btrfs/lvm are mainline.

## License

MIT
