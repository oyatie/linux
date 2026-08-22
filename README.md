# kvmhost

Stripped-down Linux kernels for a datacenter fleet: one per role — hypervisor
host, worker node, control plane, scheduler — rather than one general-purpose
distro kernel with everything switched on.

Everything starts from `allnoconfig`. Nothing is in the image unless a
fragment in `configs/fragments/` explicitly asks for it, and `make config`
fails the build if Kconfig silently dropped anything that was asked for.

```
make image                    # build the container toolchain (once)
make PROFILE=worker build     # fetch, resolve config, compile -> out/
make smoke                    # boot it under QEMU and assert on what it reports
make validate-all             # resolve + verify every profile
```

| Profile | Machine |
|---|---|
| `hypervisor` | KVM host, runs guest VMs on bare metal |
| `worker` | Runs tenant tasks in containers and sandboxes |
| `control-plane` | Replicated state machine owning cluster state |
| `scheduler` | One large CPU-bound placement process |
| `hypervisor-dpu` | KVM host whose dataplane lives on a DPU |
| `microvm` | Guest kernel (Firecracker/crosvm class) |

The builder needs **~8 GB of RAM**. Two steps are single-process memory hogs:
linking `vmlinux.o` with `DEBUG_INFO_BTF` (full DWARF in every object), and
compressing the image with `zstd -22 --ultra`. On a default Docker Desktop /
colima VM (often 2 GB) the first dies as `Error 137` and the second as a bare
`Error 11`. Either give the VM more memory, or build with the escape hatch:

```
make KVMHOST_EXTRA=opt-lowmem build   # fits in ~2 GB, no CO-RE eBPF
```

## What this is

A host kernel has an unusual shape. Almost none of the hardware a normal
kernel supports is present, the userspace is a handful of known daemons, and
the thing running on top of it is hostile by assumption. That produces a very
different config than "Ubuntu server minus some drivers":

| | |
|---|---|
| **No loadable modules** | Everything supported is linked in. Module loading is the most useful primitive an escaped guest can reach for. |
| **No swap** | A host that swaps guest RAM has already missed its latency SLO. |
| **No 32-bit userspace** | `IA32_EMULATION`, `X32`, vsyscall and `modify_ldt()` are all gone, removing the entire compat syscall entry surface. |
| **No graphics, USB, sound, wireless** | These machines have a serial console and a BMC. DRM alone is one of the largest and most CVE-dense subsystems in the tree. |
| **nftables only** | No legacy `iptables`/xtables compatibility layer. |
| **cgroup v2 only** | v1 is a second, weaker policy surface with nothing left that needs it. |
| **RAS is first-class** | EDAC, APEI/GHES, CEC and `MEMORY_FAILURE` turn a memory fault into an offlined page and one dead guest, not a dead host. |

The resolved config is ~1,600 enabled symbols, every one built in, and **zero
loadable modules**. For scale, Rocky 9 ships a similar-sized boot image and
2,370 loadable modules; Alpine's `linux-virt` ships 885. Measured comparison
against Talos, Alpine, Rocky and Oracle UEK is in `docs/COMPARISON.md`.

## Layout

```
configs/kernel.pin           which kernel release this tracks
configs/fragments/
  00-core.config             CPU, scheduler, memory, cgroups, boot
  10-virt.config             KVM, vhost, VFIO/iommufd, IOMMU, SEV/TDX
  15-vm-boot.config          virtio drivers so the image also boots in a VM
  20-storage.config          block layer, NVMe, dm-verity/crypt, filesystems
  30-net.config              stack, tenant dataplane, eBPF, NIC drivers
  40-platform.config         firmware, RAS/EDAC, IPMI, TPM, cpufreq
  50-security.config         LSMs, seccomp, hardening, mitigations, no modules
  60-observability.config    perf, ftrace, BTF, kdump, pstore
  90-strip.config            what must never come back, stated explicitly
  layer-*.config             one per role: hypervisor, worker, control-plane,
                             scheduler
  opt-*.config               guest/nested, modules, RDMA, debug, low-memory
scripts/check-config.sh      asserts the resolved .config honours every line
profiles/*.profile           which fragments compose each role's kernel
docs/DESIGN.md               why each subsystem is in or out
docs/LAYERS.md               what differs between roles, and why
docs/LIVEUPDATE.md           livepatch / kexec handover / drain, per layer
docs/MSV.md                  minimum kernel version, derived per feature
docs/COMPARISON.md           measured against Talos, Alpine, Rocky, UEK
docs/CHECKLISTS.md           capability audits + what they caught
docs/TUNING.md               boot cmdline and runtime policy for the fleet
```

## Kernel version and MSV

Pinned in `configs/kernel.pin`: **7.2**, with an enforced minimum supported
version of **7.0**.

```
make build                       # 7.2
make KERNEL_VERSION=7.3 build    # any release at or above the floor
make msv                         # recompute the floor from the features used
```

There is no LTS track. The floor is set by live update — `LIVEUPDATE`,
`LIVEUPDATE_MEMFD` and KHO-armed-at-boot are all 7.0 — and an LTS build below
it does not fail loudly, it just silently produces a kernel that cannot do a
live upgrade. `docs/MSV.md` has the per-feature table and what would move the
floor in either direction.

## Verification

`make config` resolves the fragments and then diffs intent against outcome.
This matters more than it sounds: Kconfig drops a `CONFIG_FOO=y` whose
dependencies are unmet without failing, so a kernel that builds and boots can
still be quietly missing the IOMMU, a mitigation, or KVM itself.

```
$ make config
==> baseline: allnoconfig (nothing is on until a fragment turns it on)
==> merging 9 fragments
==> verifying intent survived Kconfig resolution
check-config: all requested symbols present in .config (0 skipped)
```

It reports three ways to be wrong: `MISSING` (dependency unmet or symbol
renamed), `MISMATCH` (a different value won), and `RESURRECTED` (something
`select`s a symbol you tried to strip). Fragments are applied in order and the
last one to mention a symbol wins, so `kver-*` and `opt-*` overrides do not
trip the check.

`make smoke` then boots the image and *asserts* on it rather than eyeballing
the log — including the claims proven by absence, which are the easy ones to
get silently wrong:

```
KVMHOST ok       kvm-device               10:232
KVMHOST ok       nr-cpus                  8191
KVMHOST ok       thp-madvise              always [madvise] never
KVMHOST ok       lockdown                 none [integrity] confidentiality
KVMHOST ok       no-swap                  CONFIG_SWAP=n
KVMHOST ok       no-modules               CONFIG_MODULES=n
KVMHOST ok       no-devmem                CONFIG_DEVMEM=n
```

## Relation to minimal OS images

JeOS, Flatcar, Bottlerocket and Talos are the *userspace* half of this idea:
an immutable, stripped image with a tiny package set. They all ship a stock
distro kernel — fully modular, thousands of drivers, general-purpose — because
their kernel is not the thing they are specializing.

This repo is the other half. The production shape is a JeOS-style immutable
userspace on top of a kernel built here; `docs/DESIGN.md` describes the image
it is meant to sit in.

## Not included

No initramfs beyond the smoke-test one, no bootloader integration, no signing
keys, no host agent. Those are fleet-specific. `docs/DESIGN.md` describes the
image this kernel is meant to sit in (signed UKI, verity-backed read-only
root, kexec-based updates) and what you would have to add.
