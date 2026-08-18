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

### Explicit member order (which disks become mirror partners)

`lvcreate --type raid10 -i N` with no trailing PV list lets LVM's allocator decide
which PV carries which raid image — so **which two disks form a mirror pair is out
of the caller's hands**. Naming the PVs pins it: image *k* lands on the *k*-th
entry, and mirror partners are **adjacent** images (`(0,1)`, `(2,3)`, … — MD's near
layout with 2 copies, verified by failure injection at `-i 2` and `-i 5`).

That matters because neither LVM nor ZFS has any concept of controller/enclosure
anti-affinity: the listing order is the only lever against one hardware failure —
a cable, a sled, a backplane — taking out both halves of a mirror. This role does
not know the hardware topology. A caller that does can pass the order:

```yaml
encrypted_storage_pool_device_order:
  - 1111-aaaa        # bare crypttab name…
  - crypt-2222-bbbb  # …or a mapper name…
  - /dev/mapper/crypt-3333-cccc   # …or a full path
```

It must name **exactly** the pool's members. A partial, padded or foreign order is
**refused**, not partially applied: using it would place raid images on devices the
caller did not choose, and ignoring it would silently discard a safety decision
while leaving a pool that looks deliberate. Empty (the default) keeps the previous
behaviour — LVM allocates, and the pairing is arbitrary.

Applies to the thick data LV and to the thin pool's data LV (the raid10 one). The
`raid10` Molecule scenario imposes a *reversed* order and asserts the as-built
image→PV mapping follows it, so a silently ignored order fails CI.

### Thin-pool metadata redundancy

`lvconvert --type thin-pool` lets LVM auto-create the pool's metadata LV, and LVM makes
it **linear — on a single PV**. The data LV can be raid10 across ten disks and the pool
still dies with the one disk that happens to carry `<pool>_tmeta`: the array is intact,
the metadata is gone, and the pool cannot be activated in any mode. (LVM also tends to
place `<pool>_pmspare`, the repair-time spare copy, on that same PV.) A ZFS pool has no
such disk, because it keeps redundant metadata copies inside the pool by design.

So after the pool exists, the role converts that metadata LV into a **raid1 mirror**:

```
lvconvert -y -m 1 <vg>/<pool>_tmeta [<pv>]
```

Two consequences worth knowing:

- **It is an in-place upgrade, not just a creation-time setting.** The step runs on every
  converge, so a pool built by an earlier version of this role gains redundancy with its
  data untouched — no destroy and rebuild. It is idempotent (metadata that is already
  raid1 is skipped) and it requires the pool to be **active**, which is why the VG is
  activated first.
- **LVM keeps ownership of metadata sizing.** The default conversion runs exactly as
  before and this only adds the second copy, so there is no size heuristic in this role to
  drift from LVM's own as pools grow.

`encrypted_storage_pool_lvm_thin_meta_devices` names which member the **second** leg
should land on; the existing leg stays where LVM put it. The two legs are a mirror pair
like any other, so they should not share a controller or enclosure — that list is the hook
for fault-domain-aware placement. Left empty, LVM allocates the leg itself: still
redundant, but not yet domain-aware. Naming *only* the PV that already carries the
metadata is refused rather than ignored (raid1 legs cannot share a PV).

Set `encrypted_storage_pool_lvm_thin_meta_mirrored: false` to leave the metadata linear.

### Degraded assembly (missing device at boot)

If a member device is missing — a dead disk, or a mapper that never unlocked — the
pool comes up **degraded on the surviving copies** rather than not coming up at
all, matching what `zpool import` gives a ZFS mirror. btrfs retries with
`mount -o degraded`; the lvm backend escalates in three steps:

1. `vgchange -ay` — normal activation.
2. `vgchange -ay --activationmode degraded` — enough for a plain raid1/raid10 LV.
3. For a **thin pool**, neither of the above works: LVM refuses to activate a
   partial thin pool in `degraded` mode (*"Refusing activation of partial LV …
   Use '--activationmode partial' to override"*), so a raid10 thin pool that lost
   one disk would stay down across a reboot even though every extent still has a
   good copy. `partial` does activate it — but that mode is indiscriminate and
   would equally activate a pool that has lost *every* copy of some region,
   handing consumers a device with holes. So the escalation is **gated**:
   `/usr/local/sbin/encrypted-storage-redundancy-check` inspects
   `lvs -a -o lv_name,segtype,devices` first and only allows `partial` when every
   raid10 mirror pair still keeps an image, mirrored metadata still keeps a leg,
   and nothing non-redundant sits on a missing PV.

Not covered → the pool stays down, `encrypted-storage-ready.target` is never
reached, and consumers stay gated. That is deliberate: an uncovered loss is real
data loss, and quietly activating a holed pool is worse than not starting.

A degraded assembly logs a `WARNING … activating DEGRADED` line and tells the
operator to replace and repair; the array does **not** self-heal. Set
`encrypted_storage_pool_degraded_activation: false` to disable the escalation
entirely (any missing device then keeps the pool down).

Mirror-pair note for `raid10`: LVM builds it as MD's *near* layout with 2 copies,
so partners are **adjacent** images — `(0,1)`, `(2,3)`, `(4,5)`… The coverage gate
relies on that, and it is verified by failure injection at `-i 2` and `-i 5`
(`tests/redundancy/`). It is observed behaviour rather than a documented LVM
contract, so re-verify on a major LVM upgrade.

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
| `encrypted_storage_pool_device_order` | `[]` | Ordered member list pinning which disks become mirror partners (see [Explicit member order](#explicit-member-order-which-disks-become-mirror-partners)). Must name exactly the pool's members. |
| `encrypted_storage_pool_lvm_thin_meta_mirrored` | `true` | Convert the thin pool's metadata LV to a raid1 mirror so no single disk can destroy the pool (see [Thin-pool metadata redundancy](#thin-pool-metadata-redundancy)). |
| `encrypted_storage_pool_lvm_thin_meta_devices` | `[]` | Member(s) the **second** metadata leg may land on (crypt-`<uuid>` name or full path). Empty → LVM chooses. The fault-domain placement hook. |
| `encrypted_storage_pool_degraded_activation` | `true` | Come up DEGRADED when a device is missing but redundancy covers it (see [Degraded assembly](#degraded-assembly-missing-device-at-boot)). `false` → any missing device keeps the pool down. |
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

**Device-free (tier-0, no VMs).** Two suites, both wired into the `CI` workflow
next to yamllint/ansible-lint:

- `tests/topology/run.sh` runs the real `validate-topology.yml` guard against
  synthetic fixtures and asserts that valid setups pass and invalid ones (unknown
  topology, too-few members, odd raid10) are rejected.
- `tests/device-order/run.sh` drives the real PV-order preparation: all three
  accepted member spellings normalise to the same paths, and an order that does not
  name exactly the pool's members (missing, foreign, or duplicated) is refused.
- `tests/thin-metadata/run.sh` drives the real metadata-redundancy decision step
  against `lvs` output captured from a live thin pool before and after mirroring,
  asserting that linear metadata is detected and mirrored, that already-mirrored metadata
  is skipped (idempotence), that a candidate PV already holding the metadata is passed
  over, and that naming *only* that PV fails loudly.
- `tests/redundancy/run.sh` drives the real
  `files/encrypted-storage-redundancy-check` — the same bytes deployed to
  `/usr/local/sbin` — against `lvs` output **captured from a live LVM** with real
  devices removed, asserting that a covered loss (one disk per mirror pair, one
  metadata leg, a lost pmspare) allows degraded activation while an uncovered one
  (both members of a pair, both metadata legs, linear metadata) is refused.

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
