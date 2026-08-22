# Provider patterns, mapped

Where the well-known hyperscaler kernel adaptations land in this repo, and
what they exposed as missing.

| Provider | Their focus | Here |
|---|---|---|
| **Google** (Borg/GKE) | cgroups, BBR, massive SMP | cgroup v2 throughout (v1 refused), BBR kept for north-south, `MAXSMP`/`NR_CPUS=8192`, `sched_ext` on the worker for placement policy |
| **AWS** (Nitro, Firecracker) | virtualization offload, SR-IOV, stripped microVM host kernels | `hypervisor` (VFIO/iommufd, SR-IOV, VF live migration), `hypervisor-dpu` for the offloaded case, `microvm`/`microvm-mmio` for the guest side, `hw-nic-ena` for guests on EC2 |
| **Meta** (AI training) | eBPF traffic routing, RoCE/InfiniBand, strict NUMA | BPF/XDP/sockmap in the net base, `gpu-node` with RDMA + GPUDirect, `NUMA_BALANCING` off by policy so placement stays explicit |
| **CoreWeave** (GPU neocloud) | bare-metal DPU isolation, InfiniBand GPU-to-GPU | `hypervisor-dpu` + `gpu-node`; `hw-accel-*` for DSA/QAT |

## What these patterns exposed

**A GPU/AI node is a distinct layer, not a worker variant.** `gpu-node` runs
one very large job per machine spanning every GPU and every peer in the rail,
where the interconnect is the bottleneck and one straggler stalls a whole
collective. That forces three things the other layers refuse:

- **RDMA as the fabric**, not TCP — `INFINIBAND` + `MLX5_INFINIBAND`, with the
  CPU out of the data path.
- **GPUDirect peer-to-peer DMA** so the NIC reads GPU memory directly. Its
  dependency chain is instructive: `PCI_P2PDMA` → `ZONE_DEVICE` →
  `MEMORY_HOTPLUG` + `MEMORY_HOTREMOVE`. A GPU node therefore carries the
  memory-hotplug machinery *purely to map device memory*, not because anyone
  hot-adds DIMMs. Every other profile has hotplug off.
- **The module loader, signed.** `nvidia.ko`/`nvidia-uvm.ko` are out-of-tree
  and always will be, so this layer cannot be monolithic. DRM stays off
  regardless: CUDA/ROCm compute does not need it and a training node is
  headless.

**ENA is a guest driver, not a host driver.** It was absent because the Nitro
card presents it *to instances*. A worker or microVM running on EC2 needs
`KVMHOST_NICS=ena`; a bare-metal host never does.

## Most servers are not GPU servers

Worth stating plainly, because AI-fleet writing tends to imply otherwise: even
at an AI-heavy operator the accelerator fleet is a minority of machines. The
serving, storage, control-plane and hypervisor fleets dwarf it in machine
count, and none of them should carry a line of GPU code.

That is enforced, not assumed:

| Profile | `CONFIG_DRM` | GPU fragment |
|---|---|---|
| `hypervisor`, `hypervisor-dpu` | off | none |
| `worker`, `trusted-compute` | off | none |
| `control-plane`, `scheduler` | off | none |
| `microvm`, `microvm-mmio` | off | none |
| `gpu-node` | off unless `GPU=amd` | **`GPU=` required** |

The split got sharper in the SKU restructure: `gpu-node` is now a GPU **VM
host** — the GPU goes to a guest via VFIO, so that SKU binds no GPU driver and
`build.sh` *refuses* `GPU=` on it. The vendor fragments (`GPU=nvidia|amd`)
belong on `trusted-compute`, the first-party training metal, where
`hw-gpu-common` brings the RDMA fabric and GPUDirect P2P chain with them. A
CPU node on an RDMA fabric with no GPUs is `trusted-compute
KVMHOST_EXTRA=opt-rdma`.

## Separating what needs a GPU from what does not

GPU support is never inherited. It is selected per fleet, like the NICs, and
split by vendor because the vendor choice changes the kernel's *shape*:

| | NVIDIA (`GPU=nvidia`) | AMD (`GPU=amd`) |
|---|---|---|
| Driver | out-of-tree `nvidia.ko` | in-tree `amdgpu` + `amdkfd` |
| Module loader | **required** (signed) | not required |
| `CONFIG_DRM` | **off** — compute needs no DRM | **on** — the largest subsystem `90-strip.config` removes |
| Extra fallout | — | drags `X86_PLATFORM_DEVICES` back in |
| Symbols | 1495 | 1541 |

Neither is "better": the NVIDIA node keeps the no-DRM posture and pays with an
out-of-tree module loader; the AMD node keeps everything in-tree and pays with
DRM. Note the symbol count *understates* the AMD cost badly — `amdgpu` is the
largest single driver in the kernel tree, so +46 symbols is several MB of code.

Every non-GPU profile has `CONFIG_DRM` off and no GPU fragment at all.

## Separating by CPU vendor

One x86_64 image boots both vendors, and that is the default (`CPU=both`) —
usually right, because one image is one qualification. But it means every
machine carries the other vendor's KVM, IOMMU, EDAC, P-state driver, uncore
PMUs and confidential-computing stack.

| | symbols |
|---|---|
| `CPU=both` (default) | 1516 |
| `CPU=intel` | 1481 |
| `CPU=amd` | 1471 |

The interesting part is what the config checker caught: **speculation
mitigations follow the CPU vendor.** `MITIGATION_SRSO` and `IBPB_ENTRY` are
AMD's; `L1TF`, `MDS`, `TAA`, `RFDS`, `GDS`, `SPECTRE_BHI` and `IBRS_ENTRY` are
Intel's. Dropping a vendor drops its mitigations, which is correct — and
dangerous if the image lands on the wrong silicon. Building `CPU=amd` and
deploying it on Intel gives you a kernel with L1TF and MDS **compiled out**.
Tie the CPU fragment to the SKU in the build pipeline, not to a human.

## ARM64 / RISC-V

Not supported today: the build is `ARCH=x86_64` throughout. But the fragment
tree is less x86-bound than it looks — of 810 symbols named across all
fragments, **79 (9%) are x86/PC-platform specific**. The rest (cgroups,
namespaces, LSMs, KSPP hardening, filesystems, block, net, BPF, KVM core,
live update) is architecture-neutral.

So an ARM64 port (Graviton, Ampere, Grace) is a bounded piece of work rather
than a rewrite: an `arch-arm64.config` replacing those ~79 symbols (SMMUv3
instead of VT-d/AMD-Vi, GICv3/v4 instead of APIC, no MCE, ARM PMU, different
mitigation set), an aarch64 toolchain in the container, and a re-run of the
MSV analysis — every feature floor in `docs/MSV.md` was probed on x86.

## Profiles

| Profile | Enabled | Modules |
|---|---|---|
| `hypervisor` | 1516 | 6 (livepatch) |
| `hypervisor-dpu` | 1470 | 0 |
| `worker` | 1500 | 5 (livepatch) |
| `gpu-node` | 1495 (nvidia) / 1541 (amd) | 5 |
| `control-plane` | 1399 | 0 |
| `scheduler` | 1360 | 0 |
| `microvm` | 1138 | 0 |
| `microvm-mmio` | 1038 | 0 |
