# Size comparison

Measured, not quoted — every number below came from downloading the actual
shipped artifact in August 2026 and looking at it. Reproduce with
`scripts/compare-size.sh`.

## Boot image and modules

| Kernel | Version | vmlinuz | Modules shipped | Module bytes |
|---|---|---|---|---|
| **kvmhost** (hypervisor) | 7.2 | **13.3 MB** | **0** | **0** |
| Alpine `linux-virt` | 6.18.44 | 12.6 MB | 885 | 33 MB |
| Rocky / RHEL 9 | 5.14.0-687 | 15.2 MB | 2,370 | 72 MB |
| Oracle UEK R7 | 5.15.0-323 | 13.8 MB | 789+ | 64 MB |
| Talos Linux | v1.13.9 | 20.5 MB | in image | — |

kvmhost's 13.3 MB is the zstd figure the default config produces. The image
this repo actually built on a 2 GB builder is 15.4 MB because
`opt-lowmem.config` falls back to gzip; same kernel, 2.1 MB of compression.

## What the table actually says

**On boot image alone we are unremarkable** — 13.3 MB sits between Alpine and
UEK, and Talos, the reference "minimal OS", ships a *larger* kernel than any
of them. Anyone claiming a dramatically smaller vmlinuz is either building for
one machine or leaving the drivers in modules.

**On loadable code the gap is the whole point.** Rocky can load 2,370 modules;
we can load zero. That is not 72 MB of disk we saved, it is 2,370 pieces of
kernel code that cannot be brought into the address space of a running machine
— by an admin, by a udev rule matching an attacker-supplied device ID, or by
an exploit that got as far as `finit_module`. Alpine's `linux-virt` is the
closest comparison in spirit and still ships 885.

**Talos is the interesting one**, because its philosophy is the one we adopted.
Its kernel is bigger because it is a *general* minimal OS: it boots on
arbitrary cloud and bare-metal hardware, so it carries drivers for hardware it
has never seen. We build per fleet, so we can name the NICs
(`KVMHOST_NICS=mellanox` drops ~2 MB) and per role, so the control-plane
kernel carries no KVM at all. Talos cannot make either of those cuts and
remain Talos.

## Why "small" is the wrong metric

Boot image size is mostly a compression and driver-inventory artifact. The
numbers worth comparing are:

| | kvmhost | Rocky 9 |
|---|---|---|
| Enabled symbols | 1,601 | ~2,850 |
| Loadable modules | 0 | 2,370 |
| Reachable syscall ABIs | 64-bit only | 64-bit + ia32 + x32 |
| Filesystems mountable | 8 | 20+ |
| Packet filter uAPIs | nftables | nftables + iptables/xtables |

A kernel that is 2 MB smaller but can load a firewire driver at runtime is not
the more stripped-down of the two.

## Per-profile

| Profile | Enabled symbols |
|---|---|
| `hypervisor` | 1,601 |
| `worker` | 1,579 |
| `control-plane` | 1,531 |
| `scheduler` | 1,519 |

The spread is smaller than it looks: the shared base (core, storage, net,
platform, security, observability) is most of any kernel. What differs is
which *high-risk* subsystems are present — KVM and VFIO on the hypervisor, the
container enforcement stack on the worker, neither on the control plane.

## Method and caveats

- Talos: `vmlinuz-amd64` release asset. Its modules ship inside the OS image,
  not as a separate package, so "modules shipped" is not directly comparable —
  Talos does load modules.
- Rocky: `kernel-core` + `kernel-modules-core` + `kernel-modules`, uncompressed
  after extraction. `kernel-modules-extra` was not in the expected BaseOS or
  AppStream path at measurement time, so the real module count is higher.
- Oracle UEK: `kernel-uek-core` only; UEK splits modules across further
  packages, so 789 is a floor, not a total.
- Alpine: `linux-virt` apk, the cloud/VM-targeted flavour (not `linux-lts`).
- Versions differ (5.14 through 7.2) and compression differs between vendors;
  a megabyte here or there is not meaningful. The order-of-magnitude
  difference in loadable modules is.
