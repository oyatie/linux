# Rollout: dev -> staging -> canary -> prod

A kernel is not a web service.  Promotion here is not a code-review ladder; it
is (1) a *validation surface that widens* at each stage -- software-provable,
then real silicon, then real tenant traffic, then fleet blast-radius -- and (2)
a *rollout mechanism* that must replace a running kernel without evicting the
tenants sitting on top of it.

## Two promotion axes

- **Config / patch changes** ride dev -> staging -> canary -> prod on the
  current track (the everyday case: a fragment edit, a CVE backport).
- **The kernel-version jump** (v1 6.18 LTS -> destination 7.2) is a slower
  promotion: 6.18 holds prod while 7.2 lives permanently further left, gated
  above all on its KHO+LUO live-update handover working under real load
  (docs/LIVEUPDATE.md).  When that clears canary, 7.2 becomes the prod track.

## The stages

| stage   | validates                                                                                  | signed by | gate to leave                                             |
|---------|--------------------------------------------------------------------------------------------|-----------|-----------------------------------------------------------|
| dev     | 34-tuple matrix + QEMU smokes + reproducible build + hardening score                       | dev CA    | matrix clean, smokes pass, repro byte-identical           |
| staging | real silicon (mlx5/ice, NVMe, IOMMU, RAS, SEV-SNP/TDX, real VMMs under load) -- everything docs/EMULATION.md defers | prod key  | real-hw boot clean, SLO baselines, golden attestation captured |
| canary  | a thin prod slice under real tenant traffic, bake + auto-rollback                          | prod key  | bake elapsed, SLOs green (guest p99, panics, RAS trend, LUO handover rate) |
| prod    | progressive waves: cell -> AZ -> region, one failure domain at a time                      | prod key  | attestation-gated admission per host                      |

The dev -> staging boundary is the signing-key boundary: dev artifacts carry a
throwaway CA; staging re-signs with the production Secure Boot key (db) -- the
same re-signing point Secure Boot enforcement already assumes.

## Rollout mechanism is per-SKU

How a new kernel reaches a *running* host depends on the SKU, and the profiles
already encode it:

- **Guests (ch-guest / fc-guest)** -- replaced, not handed over.  Schedule new
  guests on the new kernel, drain the old.  Rollback = stop scheduling.
- **Hypervisor hosts (LUO track)** -- KHO+LUO live update: hand the running
  guests across a kexec, no eviction (LIVEUPDATE=yes, LUO_FLOOR=7.0).  Rollback
  = live-update back to the prior kernel.
- **VFIO / DPU hosts** -- LUO cannot hand over an assigned device, so they
  livepatch in place or drain-then-reboot (opt-livepatch is pinned on them).

The reclaim/sanitize kernel runs continuously between tenants throughout -- it
is the tenant-lifecycle plane, orthogonal to the kernel-version rollout.

## Enforcing the ladder: signed, hash-chained manifests

`scripts/promote.sh <stage> <artifact>` writes a signed manifest per stage that
pins the artifact's sha256, its .config hash, the git commit, and (from staging
on) a golden measurement.  A promotion REFUSES to advance unless the previous
stage's manifest verifies AND pins the identical artifact hash.  Two properties
fall out:

- **No stage-skipping** -- prod needs canary needs staging needs dev.
- **No swapped binary** -- the exact bits that passed canary are the bits that
  reach prod; a rebuild (different hash) fails the gate.

```
make promote-dev     PROMOTE_ARTIFACT=bzImage-hypervisor
make promote-staging PROMOTE_ARTIFACT=bzImage-hypervisor
make promote-canary  PROMOTE_ARTIFACT=bzImage-hypervisor
make promote-prod    PROMOTE_ARTIFACT=bzImage-hypervisor
```
