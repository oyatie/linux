# Verification map

What is actually proven, how, and where the ceiling is. The honest split is
not "kernel vs not" — it is **software-provable here** vs **needs real
hardware or a Linux+KVM host**.

## Proven in this environment (QEMU/TCG/HVF + containers)

| Claim | How it's proven | Command |
|---|---|---|
| Config intent survives Kconfig | every requested symbol present in resolved `.config` | `make config` (check-config.sh) |
| Nothing on that nobody decided | every default-on feature requested/implied/accepted | `make audit` |
| Fragments all reachable | reachability + profile-reference check | `make unused` |
| Both kernel tracks resolve | 30-tuple matrix, both versions, both arches | `make validate-all` |
| It boots to userspace | QEMU boot + assertions on the running kernel | `make smoke` |
| Guest kernels have no KVM/modules | per-SKU boot assertions | `make smoke PROFILE=fc-guest` |
| Host modules are signature-forced | `sig_enforce=Y` asserted at boot | `make smoke` |
| Unsigned kexec is refused | `kexec_file_load` → EPERM asserted at boot | `make smoke` |
| **Signed kexec is accepted** | trust-anchored kernel loads a signed image | `make signed-kexec` |
| Live update is live (dst track) | KHO armed + `/dev/liveupdate` present at boot | `make smoke KERNEL_VERSION=7.2` |
| Boot artifact is validly signed | UKI sbsign + sbverify against the dev CA | `make artifact` |
| Root is sealed and verifiable | dm-verity `veritysetup verify` + signed root hash | `make artifact` |
| ASLR / hardening posture | third-party KSPP/CLIP/grsec scoring | `make hardening` |
| **Signed kexec accepted** | signed image loads on a trust-anchored kernel | `make signed-kexec` |
| Reproducible build | byte-identical .config/vmlinux/bzImage across clean rebuilds | `make repro` |
| **UEFI Secure Boot enforcement** | dev CA enrolled as PK/KEK/db in OVMF; firmware launches the signed kernel and refuses a tampered one (Access Denied) | `make secureboot` |
| **KHO/LUO state handover** | a memfd's bytes survive a *signed* kexec across two kernels (in-tree luo_kexec_simple selftest) | `make luo` |
| **Hardware driver paths (emulated)** | NVMe, Intel VT-d IOMMU, multi-node NUMA and the Intel igb NIC all bind against QEMU device models under TCG | `make hw` |
| arm64 is a real target | full ship set builds + boots under HVF (KVM at EL2) | `make smoke KARCH=arm64` |

## Needs real hardware or a Linux+KVM host

| Claim | Why it can't be proven here |
|---|---|
| mlx5 / ice / bnxt datacenter NICs | QEMU models no ConnectX/E810/Thor -- only e1000e/igb/vmxnet3/virtio, so those driver paths need the real cards (the igb/e1000e/NVMe/VT-d paths ARE exercised by `make hw`) |
| SR-IOV VF live migration (mlx5) | the VFIO variant-driver path needs real mlx5 |
| SEV / TDX confidential compute | needs the silicon + firmware |
| RAS/EDAC error recovery | GHES/APEI error injection isn't cleanly exposed by this QEMU build; the EDAC/GHES *drivers* bind, but exercising a real corrected/uncorrected error needs hardware or a QEMU with ACPI error injection |
| **Real performance numbers** | every timing here is TCG/HVF — meaningless for perf (crypto throughput, boot time, packet rate) |
| Real Firecracker / Cloud Hypervisor boot | no `/dev/kvm` in the Linux VM here (HVF exposes no nested virt); `scripts/fc-smoke.sh` runs the real VMM on a KVM host |
| Bare-metal boot, DPU offload, GPU passthrough | need the hardware |
| Production workload scoping | `make audit` proves every symbol is a *decision*; it cannot prove a kept feature is ever *touched* — that needs ftrace/perf on a running fleet |

## The one-line summary

Everything that is a *property of the configuration or the boot path* is
proven here. Everything that is a *property of real silicon, real firmware
enforcement, or real load* is not, and is honestly out of reach without
hardware. The signing chain is now fully proven -- root (dm-verity signed hash), kernel
(UEFI Secure Boot launches signed, refuses tampered), and next-kernel (signed
kexec accepted, unsigned refused) -- all in-container/QEMU TCG.  And KHO/LUO carries live memfd state across that
signed kexec -- the destination track's whole reason to exist, proven with the
kernel's own selftest.