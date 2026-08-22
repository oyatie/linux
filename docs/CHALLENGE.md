# Adversarial pass

Every capability in `scripts/audit.sh`, asked the same three questions: **do we
need it, why, and on which layer?** Nothing here is justified by "distros
enable it" or "it's cheap".

The five checklists cover ~150 symbols. Most survive trivially (you cannot run
a machine without `EXT4_FS` or `PCI`), so what follows is the interesting
subset: everything that **failed** on at least one layer, plus the ones that
survived only after an argument.

## Failed — removed

| Capability | Verdict | Where |
|---|---|---|
| `CGROUP_DEVICE`, `CGROUP_NET_PRIO`, `CGROUP_NET_CLASSID`, `NET_CLS_CGROUP`, `CGROUP_FREEZER` | **Five cgroup v1 controllers on a v1-disabled kernel.** v2 does devices with BPF, classification with tc on cgroup id, and freezing in core (`cgroup.freeze`). Dead code that contradicted the design doc. | all layers |
| `OPENVSWITCH`, `VXLAN`, `GENEVE`, `MACVLAN`, `MACVTAP`, `IPVLAN` | A tenant dataplane on a node that **forwards nothing**. Each is a packet parser reachable from the network with no job to do. | control-plane, scheduler |
| `XFRM_USER`, `INET_ESP`, `INET6_ESP` | East-west encryption on these layers is mTLS terminated in the process. Carrying IPsec *and* kTLS is redundancy nobody audits. | control-plane, scheduler |
| `XDP_SOCKETS`, `BPF_STREAM_PARSER` | Dataplane accelerators. A consensus process has no packet-steering fast path to accelerate. | control-plane, scheduler |
| `XFS_FS` (+ online scrub/repair) | ~2 MB, plus a self-modifying filesystem subsystem, for data this node does not have. | scheduler |
| `NVME_FABRICS`, `NVME_TCP`, `NVME_MULTIPATH` | A node that rebuilds its state from RPC should not have its boot path depend on the network. | scheduler |
| `DM_CRYPT`, `BLK_SED_OPAL`, `FUSE_FS` | No local state to encrypt, no images to mount. | scheduler |
| `USERFAULTFD` | Exists for post-copy migration and CRIU, neither of which happens here — and it is a well-worn heap-grooming primitive in exploits. | scheduler |
| `SCHED_CORE`, `X86_CPU_RESCTRL` | Core scheduling keeps SMT siblings inside a tenant boundary; RDT stops a noisy neighbour. **There is no neighbour.** | scheduler |
| `USER_NS` | The most productive privilege-escalation surface in the modern kernel. One trusted process, no tenant code, so it pays that cost for nothing. Caveat recorded: put it back if the scheduler runs rootless. | scheduler |
| `CGROUP_MISC`, `CGROUP_HUGETLB` | SEV ASID accounting and per-container hugetlb budgets, on a node with neither. | scheduler |
| Software dataplane (OVS, bridge, encap, tc actions, conntrack) | With a DPU the card terminates the overlay and the host never touches a tenant packet. | `hypervisor-dpu` |
| `MPTCP` | For clients roaming between links. A datacenter host has bonded NICs and ECMP. | all |
| `BLK_DEV_ZONED`, `DM_INTEGRITY`, `BTRFS_FS`, `FS_DAX` | No ZNS parts, no use case, and a filesystem we do not run. | all |

## Survived, but only after argument

**`KVM` on the worker.** 1.2 MB and the full guest-facing surface on the most
exposed layer. Justified *only* because gVisor's KVM platform and microVM
sandboxes are how untrusted tenant code is contained — the alternative is
ptrace-based sandboxing, which is slower and no safer. A fleet that sandboxes
differently should strip it. Note it is KVM *only*: no VFIO, no SEV/TDX.

**`io_uring` on the worker.** This is the closest call in the tree. io_uring is
a large, fast-moving syscall surface with a long CVE history, and Android and
ChromeOS restrict it precisely because untrusted code can reach it. It stays
because the container runtime and the agent both benefit — but the worker
should run with `kernel.io_uring_disabled=1` (restricted to `CAP_SYS_ADMIN` /
`io_uring_group`), which keeps it for the agent and denies it to tenants. That
is a sysctl, not a config, and it is in `docs/TUNING.md`.

**`SELinux` on control-plane and scheduler.** No multi-tenancy to enforce, so
the multi-tenant argument fails. Kept anyway: these nodes run third-party
monitoring and management agents, and SELinux is what confines *those*. The
LSM stack is the defence against the software you did not write.

**`SYSVIPC`.** Legacy IPC, and modern VMMs use memfd/POSIX shm. Kept because
some datastores still require it and the cost is small — the weakest
justification in this document, and a fair thing to cut.

**`NUMA_BALANCING` on host layers.** Compiled in while `TUNING.md` tells you to
disable it at runtime, because the VMM knows the topology it advertised and the
kernel's balancer does not. Kept only for fleets running unpinned workloads. If
yours always pins, remove it.

**`PTP_1588_CLOCK` everywhere including the guest.** Survives because guests
want `ptp_kvm` for host clock sync, which is genuinely better than NTP over the
tenant network. `NETWORK_PHY_TIMESTAMPING` does not apply in a guest and is
carried only because it costs a few KB.

**`cgroup v2` on the scheduler.** Marginal: one process on a dedicated machine
needs no enforcement. Kept for accounting and PSI. It would survive without it.

## Result

| Profile | Enabled symbols |
|---|---|
| `hypervisor` | 1,608 |
| `hypervisor-dpu` | 1,571 |
| `worker` | 1,586 |
| `control-plane` | 1,503 |
| `scheduler` | 1,460 |
| `microvm` | 1,230 |

Before this pass the spread between the heaviest and lightest *host* profile
was 82 symbols, most of it accidental. It is now 126, and every symbol of the
difference is a decision with a sentence attached.
