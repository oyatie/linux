# Design

Why this kernel is shaped the way it is. Each section is a decision, the
reason for it, and what it costs.

## The threat model

The host kernel is the trust boundary for every VM on the machine. Ordered by
what actually happens in practice:

1. **Guest → host escape.** The guest's reachable surface is the VMM process
   plus whatever the VMM can reach in the kernel: KVM's MMU and instruction
   emulator, `vhost-net`/`vhost-vsock`, and any assigned device's DMA path.
2. **Tenant → tenant through shared microarchitecture.** L1TF, MDS, and their
   successors. Kernel config covers the kernel half; the fleet half is core
   scheduling and SMT policy (see `TUNING.md`).
3. **Compromised host agent seeking persistence.** The monitoring or control
   agent is on the host, is large, and is written by someone else.

Everything below follows from those three.

## Monolithic: no loadable modules

`CONFIG_MODULES` is off. Every driver this platform supports is linked into
the image.

Loading a module is the highest-leverage primitive an attacker who has reached
root-in-the-host can use, and signing does not fix it — it narrows who can
sign, not what a signed-but-vulnerable module does. Removing the mechanism
removes the whole class, along with `finit_module`, module-parameter parsing,
and the `.ko` load path.

**Cost:** no out-of-tree drivers, and a fleet with a vendor accelerator will
need `opt-livepatch.config` (which turns modules back on with `MODULE_SIG_FORCE`).
The image is larger, since drivers that would be modules are always resident.

## Attack surface removed outright

The `90-strip.config` fragment states these explicitly rather than relying on
the `allnoconfig` baseline, so that a future `select` that drags one back in
fails `check-config.sh` instead of shipping.

- **DRM/framebuffer/VGA.** No displays. DRM is one of the biggest and most
  vulnerability-dense subsystems in the tree.
- **USB, Thunderbolt, FireWire, MMC.** Nobody plugs anything into a machine in
  a cold aisle, and several of these are DMA-capable.
- **Wireless, Bluetooth, CAN, ATM, NFC.**
- **32-bit userspace.** `IA32_EMULATION`, `X86_X32_ABI`, `COMPAT`,
  `MODIFY_LDT_SYSCALL`, vsyscall emulation. This deletes an entire second
  syscall entry path and its argument-translation layer.
- **`/dev/mem`, `/dev/port`, `/proc/kcore`.**
- **Legacy iptables.** nftables is the only packet-filter uAPI here.
- **cgroup v1.** Including `MEMCG_V1`.

Two things resist stripping and are documented in place: `I2C` (the Intel NIC
drivers select it for SFP+ module EEPROM access) and `PNP` (ACPI selects it).

## Virtualization

- **Both `KVM_INTEL` and `KVM_AMD`** are built in. A fleet image boots on
  either vendor; the alternative is two images and a class of deployment bug.
- **`KVM_SMM`** stays because OVMF and SeaBIOS need it — that is, every
  general-purpose guest image.
- **`KVM_HYPERV`** stays because Windows guests are a large share of any public
  cloud and run measurably worse without the enlightenments.
- **`KVM_XEN` is off.** Xen PV guests are not this platform's product.
- **Confidential computing** is on for both vendors: `KVM_AMD_SEV` (with the
  CCP/PSP driver, without which SEV silently does not work) and
  `INTEL_TDX_HOST`. TDX drags in `CONTIG_ALLOC`, which on this config only
  comes from `CMA`; CMA reserves nothing unless `cma=` is on the command line.
- **`vhost-net` and `vhost-vsock`** are in-kernel datapaths; `vhost-scsi` is
  not, because storage goes through the VMM where it can be sandboxed.
- **Device assignment** uses `iommufd` with `VFIO_CONTAINER` kept for control
  planes still on the type1 ioctls. `MLX5_VFIO_PCI` is the variant driver that
  makes SR-IOV VF live migration possible — without it you cannot evacuate a
  host without disconnecting every guest holding a VF.
- **IOMMU defaults to strict invalidation.** A passed-through device is under
  tenant control, and lazy invalidation leaves a window where a freed IOVA is
  still DMA-reachable. It costs unmap throughput; `iommu.strict=0` buys it back
  on hosts where you own every assigned device.
- **`INTEL_IOMMU_SVM` is off.** Shared virtual addressing hands a device the
  CPU page tables. Not on a multi-tenant machine.

## Memory

- **No swap.** Not a tuning choice — `CONFIG_SWAP` is off. Swapping guest RAM
  destroys the latency guarantee the instance is sold with. (Memory
  oversubscription for burstable instance types is a different design: it
  needs swap or tiering deliberately re-enabled, plus a balloon/free-page
  reporting path in the guest.)
- **`KSM` is off.** Same-page merging across tenants is a documented
  side-channel and a cross-domain information leak by construction.
- **`HUGETLB_PAGE_OPTIMIZE_VMEMMAP`** frees most of the `struct page` array
  backing hugetlb pages. On a host handing out hundreds of GB of 1G pages that
  is percent-level RAM recovered — memory you can sell.
- **`DEFERRED_STRUCT_PAGE_INIT`** parallelizes `struct page` init across nodes.
  On a multi-TB host this is tens of seconds off every boot, and boot time is
  fleet capacity during a mass reboot.
- **THP is `madvise`-only.** The VMM asks for what it wants; nothing else on
  the host should be silently promoted.
- **`MEMORY_FAILURE` + `RAS_CEC` + APEI.** An uncorrectable ECC error in guest
  memory should offline the page and kill one VM. Without this it is a host
  panic and every VM on the box dies.
- **`USERFAULTFD`** is required for post-copy live migration.

## Scheduling and isolation

`NO_HZ_FULL`, `RCU_NOCB_CPU` and `CPU_ISOLATION` are built in but not
configured — which CPUs are isolated is a boot-time decision (`TUNING.md`),
because it depends on the host's core count and NIC IRQ layout.

`SCHED_CORE` (core scheduling) is on. It is what lets you keep SMT enabled
while guaranteeing that two hyperthread siblings only ever run the same
trust domain — the alternative is `nosmt` and roughly half the machine.

`PREEMPT_LAZY` with `PREEMPT_DYNAMIC`: throughput close to `PREEMPT_NONE` with
a bounded latency tail, and `preempt=` still tunable at boot without a rebuild.
(On 6.18 and earlier x86 also offered `PREEMPT_VOLUNTARY`; 7.2 dropped that
option once `ARCH_HAS_PREEMPT_LAZY` landed.)

`MAXSMP` pins `NR_CPUS` to 8192. Not vanity: a 2-socket Turin host is 768
threads, and the 512-CPU ceiling of a non-`MAXSMP` build will not boot it.

## Storage and the root image

The intended image is a **signed UKI** (kernel + initramfs + cmdline in one
PE binary, measured by Secure Boot) whose root is a **read-only erofs or
squashfs under dm-verity**, with `overlayfs` + `tmpfs` for the writable parts
and local NVMe for guest disk images. Hence: erofs, squashfs, overlayfs,
dm-verity, dm-crypt, ext4, xfs — and nothing else. Every additional filesystem
is a parser reachable by handing the host an image.

`NVME_TCP`/`NVME_FABRICS` are in because remote block storage is normal in
cloud; SATA/AHCI is in only because boot media is often an M.2 SATA part.

## Security posture

- **LSM stack:** `landlock,lockdown,yama,bpf,selinux`. Lockdown is in
  *integrity* mode from early boot, which closes the kernel-image write paths
  (`/dev/mem`, unsigned kexec, raw MSR writes, kprobe abuse of BPF).
- **seccomp** is mandatory, not optional: crosvm, Firecracker and QEMU under
  libvirt all drop into a seccomp jail after setup, and without
  `SECCOMP_FILTER` that sandbox is decorative.
- **eBPF:** JIT always on (no interpreter to attack), unprivileged BPF off by
  default. BPF is a host-agent tool here, not a tenant-facing one.
- **Hardening:** `INIT_ON_ALLOC_DEFAULT_ON`, `INIT_STACK_ALL_ZERO`,
  `HARDENED_USERCOPY`, freelist randomization/hardening,
  `RANDOMIZE_KSTACK_OFFSET`, `X86_KERNEL_IBT`, `X86_USER_SHADOW_STACK`,
  `SLAB_MERGE_DEFAULT` off. These cost single-digit percent; a hypervisor host
  is the machine where that trade is obviously worth it.
- **Speculative execution mitigations** are all compiled in. Whether to run
  with SMT on, and which mitigations to relax, is fleet policy expressed on the
  command line — not something to bake into an image you cannot change without
  a reboot.

## Observability

Chosen so that everything is either patched-out-until-armed or passive:

- `DEBUG_INFO_BTF` for CO-RE eBPF. Inflates `vmlinux`, not `bzImage` — but it
  also puts full DWARF in every object, so the builder needs ~8 GB to link.
  `opt-lowmem.config` trades it away when you only need a compile test.
- ftrace/kprobes/uprobes/`perf`, `PSI`, `SCHEDSTATS`, delay accounting.
- **kdump via `kexec_file_load` only.** The old `kexec_load` takes an
  unverified image from userspace, which lockdown forbids anyway.
- `pstore` (RAM + EFI variables) for the case where kdump itself does not
  survive the crash.
- Deliberately absent: KASAN, lockdep, `DEBUG_VM`. They belong on a canary
  host — `opt-debug.config` — not on the fleet.

## What is missing

This is a kernel, not a host image. Still required for something bootable in
production: an initramfs with the verity root setup, a signing pipeline and
enrolled keys for Secure Boot and (if enabled) module and kexec signatures, a
bootloader or direct-UKI boot path, and the host agent. The kexec-based live
update path — load the next kernel with `kexec_file_load`, drain, jump — is
the reason `KEXEC_FILE` and `CRASH_HOTPLUG` are here, but the orchestration
around it is fleet-specific.
