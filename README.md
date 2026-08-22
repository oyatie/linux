# kvmhost

A stripped-down Linux kernel for machines whose only job is running virtual
machines — the host kernel underneath a fleet of KVM hypervisors, not a
general-purpose server distro kernel with virtualization switched on.

Everything starts from `allnoconfig`. Nothing is in the image unless a
fragment in `configs/fragments/` explicitly asks for it, and `make config`
fails the build if Kconfig silently dropped anything that was asked for.

```
make image      # build the container toolchain (once)
make build      # fetch source, resolve config, compile -> out/bzImage
make smoke      # boot it under QEMU and assert on what it reports
```

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

The resolved config is ~1,570 enabled symbols, every one of them built in and
zero loadable modules — where a distro server kernel enables a comparable
number of built-ins *plus* several thousand modules covering hardware this
machine will never have.

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
  kver-<x.y>.config          per-release deltas (symbols get renamed upstream)
  opt-*.config               guest/nested, modules, RDMA, debug, low-memory
scripts/check-config.sh      asserts the resolved .config honours every line
docs/DESIGN.md               why each subsystem is in or out
docs/TUNING.md               boot cmdline and runtime policy for the fleet
```

## Kernel version

Pinned in `configs/kernel.pin`, currently **7.2** (mainline), with **6.18.45**
(longterm) validated as the conservative track:

```
make build                        # 7.2
make KERNEL_VERSION=6.18.45 build # LTS track
make validate-matrix              # resolve the fragments against both
```

Mainline is the right default when you are landing new silicon — platform
bring-up (Zen 6, Nova Lake) lands there and is not backported to LTS in any
complete form. The tradeoff is real and worth restating: a `.0` release has no
stable point releases behind it yet, and on a hypervisor host a regression is
a few hundred tenants, not one machine. Run `make validate-matrix` before
moving either pin.

`kver-*.config` exists because symbols drift between releases. A concrete one
this repo already hit: `BOOTPARAM_SOFTLOCKUP_PANIC` is a bool in 6.18 and an
int in 7.2.

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
