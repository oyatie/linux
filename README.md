# kvmhost

Stripped-down Linux kernels for a hyperscale datacenter, built around one
structural fact: the plant is **hypervisor metal plus guests**.  Tenant code
runs in Cloud Hypervisor / Firecracker VMs, and so does almost everything
else — the control plane, schedulers, and node agents are guests too.  So the
v1 ship set is exactly three kernels, not a Borg-style stable of metal roles:

| v1 ship set | |
|---|---|
| `hypervisor` | the bare-metal KVM host under CH/FC VMMs |
| `ch-guest` | the general guest: sold VMs and first-party serving |
| `fc-guest` | the Firecracker guest: MMIO-only, viciously small |

Everything starts from `allnoconfig`. Nothing is in the image unless a
fragment in `configs/fragments/` explicitly asks for it, and `make config`
fails the build if Kconfig silently dropped anything that was asked for.

```
make image                      # build the container toolchain (once)
make build                      # v1 hypervisor on the LTS track -> out/
make PROFILE=fc-guest build     # guest kernels also emit an ELF vmlinux
make smoke PROFILE=fc-guest     # boot + assert (QEMU microvm stand-in)
make validate-all               # the shippable matrix, on both tracks
```

Later SKUs (validated today, shipped when the product exists): `hypervisor-dpu`
(the card terminates the overlay), `gpu-node` (GPU-VM passthrough host — binds
no GPU driver), `trusted-compute` (first-party metal, IOMMU passthrough;
`GPU=nvidia|amd` makes it a training node), `ch-guest-k8s` (containers inside
a CH guest, if we sell kube).

Orthogonal knobs: `KARCH=x86_64|arm64`, `CPU=intel|amd` (x86 only),
`GPU=nvidia|amd` (training metal only), `KVMHOST_NICS=...`,
`ACCEL=intel-dsa|intel-qat` (x86 only), `PLATFORM=vm`,
`KVMHOST_EXTRA=opt-windows|opt-rt|opt-lowmem|opt-fastboot`.

**Architecture is a first-class axis.** Shared fragments are arch-neutral;
anything silicon-specific lives in a `<name>.<arch>.config` sibling appended
automatically — vendor KVM, SEV/TDX and the `MITIGATION_*` set on x86;
SMMUv3, PL011, PAuth/BTI/MTE and CPPC on arm64. `make KARCH=arm64 build`
produces `out/Image-<profile>-arm64`, and the validation matrix resolves the
arm64 ship set against both kernel tracks alongside x86.

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
  15-vm-boot.config          virtio drivers so the image also boots in a VM
  20-storage.config          block layer, NVMe, dm-verity/crypt, filesystems
  30-net.config              stack, tenant dataplane, eBPF, NIC drivers
  40-platform.config         firmware, RAS/EDAC, IPMI, TPM, cpufreq
  50-security.config         LSMs, seccomp, hardening, mitigations, no modules
  60-observability.config    perf, ftrace, BTF, kdump, pstore
  90-strip.config            what must never come back, stated explicitly
  layer-*.config             hypervisor (KVM/vhost/VFIO/SEV/TDX + v1 overlay),
                             ch-guest, fc-guest, containers
  platform-vm.config         the metal/vm axis: strips RAS/BMC/pstates, adds
                             paravirt + PVH direct boot
  opt-*.config               windows guests, RT, RDMA, debug, low-memory
  configs/sysctl.d/          image policy the kernel cannot express as Kconfig
  configs/accept-defaults.config  reviewed default-on features (the audit ledger)
scripts/check-config.sh      asserts the resolved .config honours every line
profiles/*.profile           which fragments compose each role's kernel
docs/DESIGN.md               why each subsystem is in or out
docs/LAYERS.md               what differs between roles, and why
docs/LIVEUPDATE.md           livepatch / kexec handover / drain, per layer
docs/MSV.md                  minimum kernel version, derived per feature
  docs/HARDENING.md            independent KSPP/CLIP/grsec audit + divergences
docs/COMPARISON.md           measured against Talos, Alpine, Rocky, UEK
docs/PROVIDERS.md            provider patterns; GPU and CPU vendor splits
docs/CHECKLISTS.md           capability audits + what they caught
docs/TUNING.md               boot cmdline and runtime policy for the fleet
```

## Version policy: two tracks

`configs/kernel.pin` pins both. **v1 is the LTS track** (currently 6.18.45):
kernel updates are `kexec_file_load` + drain, plus livepatch on VFIO hosts.
**Destination is 7.2**: the Live Update Orchestrator (KHO + LUO + memfd
handover) turns a host kernel update into ~1s of blackout — but LUO does not
exist below 7.0, so it gates the destination, not the plant. `validate-all`
resolves every shippable tuple against both tracks so the move is a version
bump, not a migration. The hard floor for any build is `MSV=6.18`
(`docs/MSV.md` has the per-feature derivation).

## Verification

`make config` resolves the fragments and then diffs intent against outcome.
This matters more than it sounds: Kconfig drops a `CONFIG_FOO=y` whose
dependencies are unmet without failing, so a kernel that builds and boots can
still be quietly missing the IOMMU, a mitigation, or KVM itself.

```
$ make config
==> verifying intent survived Kconfig resolution
check-config: all requested symbols honoured in .config
```

Two verifiers, two failure modes. `check-config` proves every symbol a
fragment *asked for* survived Kconfig resolution (dependencies can silently
drop a `=y`). `make audit` proves the converse -- that nothing is on that
*nobody asked for*: every default-on feature must be requested by a fragment,
implied by a dependency, or listed in `configs/accept-defaults.config` with a
reason. Together they make the enabled set exactly the decided set, so
"purposefully scoped" is an invariant the build enforces, not a claim:

```
$ make audit
audit OK: every default-on feature is accounted for (125 accepted,
          224 promptless internals ignored)
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
