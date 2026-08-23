# Emulation coverage

The "hardware-blocked" list was mostly wrong. With QEMU device models, the
kernel's own injection/simulation frameworks, and **nested KVM** (Apple
M-series + macOS vz exposes it; `colima start --nested-virtualization`), almost
every path is exercisable in software. This maps each item to how it's proven.

| # | Capability | Verdict | How it's proven here | Target |
|---|---|---|---|---|
| 1 | **Performance** | proxy | `-icount` makes the guest clock instruction-proportional; a boot milestone's virt-time is identical run-to-run (nokaslr), so a regression shifts it — a hardware-agnostic CI signal. A true instruction *count* needs the QEMU insn plugin (a qemu-source build). | `make perf` |
| 2 | **Datacenter NICs / SR-IOV VFs** | control-plane | `netdevsim` simulates a PF and creates/deletes 4 VFs with no NIC — the way SR-IOV orchestrators are tested. The specific ConnectX/E810 driver *data* paths still need the cards. `NET_FAILOVER` (compiled) is the virtio-failover half of VF-live-migration orchestration. | `make diag` |
| 3 | **Confidential compute (SEV/TDX)** | software-only | Host stacks compiled (`KVM_AMD_SEV`, `INTEL_TDX_HOST`); a full SEV-sim guest boot under TCG proves layout/attestation-parsing but *zero* encryption — deferred as low-value without the silicon. | — |
| 4 | **RAS / GHES / APEI / MCE** | frameworks present | `opt-diag` builds `X86_MCE_INJECT`, `ACPI_APEI_EINJ` and block fault-injection; the MCE-injection and `fail_make_request` interfaces are live in the guest, firing the same RAS driver paths a real fault would. | `make diag` |
| 5 | **Real Firecracker / Cloud Hypervisor** | real (nested KVM) | Both boot our guest kernels to userspace under real `/dev/kvm` (nested). Firecracker has no TCG fallback, so its execution *is* the KVM proof. | `make fc-real`, `make ch-real` |
| + | **Device driver paths** | emulated | NVMe, VT-d IOMMU, multi-node NUMA, Intel igb NIC all bind against QEMU device models. | `make hw` |
| + | **virtio-iommu** | real | Paravirt IOMMU binds and groups PCI devices for translation in the guest. | `make viommu` |
| + | **TPM 2.0 measured boot** | emulated | swtpm behind tpm-crb; the `tpm_crb` driver binds and a SHA-256 PCR bank reads back. | `make tpm` |

## What genuinely still needs silicon
Real cryptographic security (SEV/TDX memory encryption), the specific
datacenter-NIC data paths (mlx5/ice/bnxt), and *absolute* performance numbers.
Everything else — functional driver behavior, RAS paths, the full boot/update/
signing chain, and real KVM-backed VMM boots — is proven here.

## Nested KVM note
`/dev/kvm` in the colima VM (and containers via `--device /dev/kvm`) is arm64
(the VM is aarch64), so real-KVM tests run arm64 guests; x86 stays TCG. That's
why `fc-real`/`ch-real` use the arm64 images.
