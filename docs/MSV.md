# Minimum supported version

**MSV = 7.0.** Enforced: `make` refuses to build below it, before it downloads
anything.

The floor is not a preference. It is the maximum over the floors of every
feature the platform actually depends on, and it is derived rather than
remembered — `scripts/feature-floor.sh` probes each symbol's defining Kconfig
at each release tag. Regenerate with `make msv`.

## Per-feature floors

| Feature | Symbol | Floor |
|---|---|---|
| Live Update Orchestrator | `LIVEUPDATE` | **v7.0** |
| LUO memfd handover | `LIVEUPDATE_MEMFD` | **v7.0** |
| KHO armed at boot | `KEXEC_HANDOVER_ENABLE_DEFAULT` | **v7.0** |
| Kexec handover | `KEXEC_HANDOVER` | v6.18 |
| KVM TDX | `KVM_INTEL_TDX` | v6.18 |
| Lazy preemption | `PREEMPT_LAZY` | v6.18 |
| Intel TDX host | `INTEL_TDX_HOST` | v6.12 |
| Hyper-V enlightenments | `KVM_HYPERV` | v6.12 |
| Mitigation symbol names | `MITIGATION_RETPOLINE` | v6.12 |
| cgroup v1 separable | `MEMCG_V1` | v6.12 |
| iommufd | `IOMMUFD` | v6.6 |
| VFIO cdev uAPI | `VFIO_DEVICE_CDEV` | v6.6 |
| User shadow stack (CET) | `X86_USER_SHADOW_STACK` | v6.6 |
| Disable TIOCSTI | `LEGACY_TIOCSTI` | v6.6 |
| AMD SEV, core scheduling, RDT, io.cost, landlock, mlx5 VF migration, hugetlb vmemmap opt, static usermode helper, zero-call-used-regs | — | ≤ v6.1 |

Three features set the floor, and they are the same feature in three parts:
**live update**. Everything else this platform uses has been available since
6.6 or earlier.

## Why there is no LTS track

The repo previously validated 6.18 LTS alongside mainline. That is dropped.

An LTS build below the floor does not fail — it silently produces a kernel
without live update, because Kconfig drops symbols that do not exist yet.
(`check-config.sh` catches it, which is how the gap was found in the first
place.) Maintaining that track meant maintaining a second, quietly degraded
product whose main upgrade story did not work.

The 6.18 track also carried a conflict worth recording: its KHO had
`depends on !DEFERRED_STRUCT_PAGE_INIT`, so fast boot and live update were
mutually exclusive there. Above the floor they coexist.

## What would move the floor

Raise it: adopting a feature that lands later — a new KVM interface, an
iommufd capability, LUO support for a device class you need handed over.

Lower it: dropping live update. Without LUO the floor falls to **v6.6**
(iommufd + VFIO cdev + CET), which would put an LTS back in range. That is the
trade, and it is a product decision, not a build one — a fleet without live
update patches by draining and rebooting every machine.

## Caveat on the method

Symbol presence in Kconfig is a proxy for feature availability. It does not
capture a feature that landed incomplete or was only wired up for one
architecture, and symbol renames must be listed explicitly (`RETPOLINE`
became `MITIGATION_RETPOLINE` at 6.9). The probe now fails loudly rather than
reporting "absent" when a Kconfig path is stale — an earlier version of this
table wrongly showed `HUGETLB_PAGE_OPTIMIZE_VMEMMAP` as missing because it
lives in `fs/Kconfig`, not `mm/Kconfig`.
