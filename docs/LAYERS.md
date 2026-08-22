# SKUs

One structural fact drives the whole map: **tenant code runs in VMs, and so
does almost everything first-party.** The metal fleet is hypervisors; the
control plane, schedulers and node agents are guests on top of it. Kernels
follow that shape.

## v1 ship set

| SKU | Runs on | What it is |
|---|---|---|
| `hypervisor` | metal | KVM host under Cloud Hypervisor / Firecracker. KVM both vendors, vhost, VFIO/iommufd + SR-IOV, SEV/TDX, the v1 software overlay, strict IOMMU. Modules exist **only** for signed livepatch. |
| `ch-guest` | VM | The general guest: sold VMs and first-party serving. Deliberately not minimal — full base (NUMA, big NR_CPUS, XFS/ext4, BPF, io_uring, kdump) plus CH's ACPI hotplug, virtio-fs, virtio-iommu, kTLS. Ships bzImage **and** ELF vmlinux. |
| `fc-guest` | VM | The function/container-instance guest under Firecracker: virtio-mmio devices from the kernel command line, no PCI, no ACPI, no EFI, no NUMA, 64 CPUs. Viciously small is the point. |

Control plane and schedulers run **on `ch-guest`**. They are processes with
replicas, not kernels: giving each a bespoke metal kernel was Borg cosplay,
and it died in review. (`docs/CHALLENGE.md` records the earlier per-role
audit; those roles now describe workloads, not SKUs.)

## Later SKUs — validated in the matrix today, shipped when the product exists

| SKU | Runs on | Trigger |
|---|---|---|
| `hypervisor-dpu` | metal | The DPU terminates the overlay; host loses OVS/VXLAN/conntrack entirely. Destination for the plant. |
| `gpu-node` | metal | Selling GPU VMs. A **passthrough host**: the GPU goes to the guest via VFIO, so this SKU binds no GPU driver and `build.sh` refuses `GPU=` on it. Differs from `hypervisor` at runtime (1G hugepages, vfio-pci binding), not in config. |
| `trusted-compute` | metal | First-party services on metal: one trust domain, IOMMU passthrough (untranslated DMA), no KVM. `GPU=nvidia\|amd` turns it into the training node — RDMA fabric, GPUDirect P2P, vendor driver. |
| `ch-guest-k8s` | VM | Only if we sell managed kube: the container stack (cgroup enforcement, IPVS, dm-crypt scratch) inside a CH guest. Pairs with `configs/sysctl.d/ch-guest-k8s.conf`, which fences io_uring away from tenant containers. |

## The axes

Every kernel is `profile × platform × cpu × hardware knobs`:

- **PLATFORM=metal|vm** — arguably decides more than the profile: metal owns
  memory errors, the BMC, microcode, P-states and real NICs; a VM owns none of
  that, and `platform-vm.config` also supplies paravirt (kvm-clock, PV
  spinlocks, ptp_kvm, vsock, balloon) and the PVH entry for direct boot.
- **CPU=both|intel|amd** — single-vendor drops the other's KVM/IOMMU/EDAC
  stack *and its mitigations*; tie it to the SKU in the pipeline, never to a
  human (`CPU=amd` deployed on Intel = L1TF compiled out).
- **NICs / accelerators / GPUs** — per-fleet parts. Host SKUs pin what the
  fleet buys (`NICS="mellanox"`); guests are virtio-only; `ena` is what a
  *guest* sees on EC2 and the build refuses it on metal.

## Architecture

`KARCH=arm64` builds the same SKUs for Graviton/Ampere/Grace-class machines.
The port surfaced real asymmetries, recorded in the per-arch fragments rather
than papered over:

- **No HVO on arm64** — the hugetlb vmemmap optimization is x86/loongarch/
  riscv-only upstream, so the struct-page RAM recovery that helps 1G-page
  fleets on x86 does not exist there. The memory math differs.
- **Kernel BTI is clang-only** (`depends on !CC_IS_GCC`); with a GCC
  toolchain, arm64 gets userspace BTI + PAuth + MTE, not kernel BTI.
- **No SEV/TDX counterpart yet** — Arm CCA's host side is not complete
  upstream at our floors; `layer-hypervisor.arm64.config` says so explicitly.
- **RAS converges on APEI/GHES** — the vendor EDAC drivers and the
  corrected-error collector are x86 MCE machinery; arm64 reports through
  the same ACPI path both arches already share.

## Numbers

Regenerate with `make validate-all`; representative counts (`=y`, v1 track):
hypervisor ~1510, ch-guest ~1150, fc-guest ~1030, trusted-compute ~1380.
The gap between hypervisor and fc-guest — roughly a third of the kernel — is
the measure of what "the host owns the machine, the guest owns nothing"
actually buys.
