# Capability audits

`scripts/audit.sh <checklist>` reads the resolved `out/<profile>.config` files
and prints capability × profile. It reports what the artifact *has*, not what
the fragments *intended* — which is the point, since those diverge.

```
make validate-all          # regenerate every profile's config
./scripts/audit.sh isolation
./scripts/audit.sh network
./scripts/audit.sh memory
./scripts/audit.sh scheduling
./scripts/audit.sh storage
```

## What the audits found

Running these against the tree caught six real defects. They are recorded here
because each one is a class of mistake, not a one-off.

**Four cgroup v1 controllers on a v1-disabled kernel.** `CGROUP_DEVICE`,
`CGROUP_NET_PRIO`, `CGROUP_NET_CLASSID` and `NET_CLS_CGROUP` are all v1-only
constructs — on v2, device access is enforced with BPF and classification is
done with tc keyed on cgroup id. They were dead code that also contradicted
the "v2 only" claim in the design doc. *Class: a config can assert a policy in
one file and violate it in another.*

**`HUGETLB_PAGE_OPTIMIZE_VMEMMAP` compiled in but inert.** The design doc
claimed percent-level RAM recovery from it. True only with
`..._DEFAULT_ON=y` or `hugetlb_free_vmemmap=on` on every command line;
without either, the feature is present and does nothing. *Class: a symbol
being `=y` does not mean the behaviour is active.*

**XFS online scrub and repair were on by Kconfig default**, never decided.
A filesystem that repairs itself while mounted is a real behaviour change.
They are now stated explicitly (and kept). *Class: `olddefconfig` fills in
defaults, so "not in a fragment" does not mean "off".*

**`MISC_FILESYSTEMS` silently flipped off** in the guest profile, taking
squashfs with it, because it too was riding a Kconfig default. *Same class,
found the hard way.*

**kTLS and sockmap/sk_msg entirely absent** from a config that claims to be a
high-performance networking platform. *Class: absence is invisible until you
enumerate what you expected.*

**`UCLAMP` and `sched_ext` absent.** Without utilization clamping,
`cpu.weight` is the only QoS lever and it says nothing about frequency or
placement urgency. *Same class.*

## Adversarial review: do we actually need these?

### cgroup v2 — yes, but it is load-bearing on exactly one layer

| Layer | Verdict |
|---|---|
| `worker` | **Essential.** It *is* the enforcement mechanism. Without `cpu.max`, `memory.max` and `io.cost` the agent can only ask tasks nicely. |
| `hypervisor` | **Yes**, for per-VM accounting, VMM sandbox limits, and `CGROUP_MISC` (SEV ASIDs are a cgroup-accounted resource). |
| `control-plane` | **Yes, but for a different reason** — not multi-tenancy, but keeping the node agent from starving the consensus process. |
| `scheduler` | **Marginal.** One large process on a dedicated machine. Kept for accounting and PSI, not for enforcement. Honest answer: it would survive without it. |
| `microvm` | **Debatable.** A single-workload guest does not need controllers; a guest running a container runtime does. Kept, because most do. |

### SR-IOV / DPU passthrough — needed on one layer, and it *shrinks* the kernel

`hypervisor` only. `worker` gets none (containers use veth/ipvlan; an AI/HPC
worker with RDMA is a different profile), and `control-plane`/`scheduler`
should never have device assignment at all — there is no workload there to
assign a device to.

The interesting part is the DPU case, which inverts the usual argument. With a
Nitro-class DPU the card terminates the overlay: encap/decap, security groups,
conntrack and rate limiting all happen on the card, and the host kernel never
touches a tenant packet. So the software dataplane — OVS, bridge, VXLAN,
GENEVE, tc actions, conntrack, mlx5 TC offload — is attack surface for a job
nobody on that machine is doing.

`PROFILE=hypervisor-dpu` strips it. What stays is device assignment:
VFIO/iommufd, SR-IOV, PCIe hotplug, and the vendor VFIO variant driver for VF
live migration.

### NUMA — yes on every host layer, and stripping it from the guest is a trap

`hypervisor`, `worker`, `scheduler`, `control-plane`: yes. These are 2-socket
machines; without NUMA the kernel cannot even describe the topology the
placement decisions depend on.

`microvm`: stripped — **and that is only correct for guests that fit in one
node**. A large instance is sold *with* vNUMA, and a guest kernel without
`CONFIG_NUMA` cannot place its own memory: it scatters allocations across both
vNUMA nodes and loses exactly the locality the customer paid for. The caveat
is recorded in `strip-host.config`; a large-instance guest profile must put
NUMA and a higher `NR_CPUS` back.

One honest wart: `NUMA_BALANCING` is compiled into the host profiles while
`docs/TUNING.md` tells you to disable it at runtime, because the VMM knows the
topology it advertised and the kernel's balancer does not. It is kept only for
fleets that run unpinned workloads. If yours always pins, it is removable.
