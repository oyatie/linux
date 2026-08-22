# Layers

One kernel per role, not one kernel for the fleet. Each layer shares a base
(`00-core`, `20-storage`, `30-net`, `40-platform`, `50-security`, `55-kspp`,
`60-observability`, `70-liveupdate`, `90-strip`) and adds exactly one
`layer-*.config`.

| Profile | Machine | Enabled symbols |
|---|---|---|
| `hypervisor` | KVM host, runs guest VMs on bare metal | 1608 |
| `worker` | Runs tenant tasks in containers and sandboxes | 1586 |
| `control-plane` | Replicated state machine owning cluster state | 1503 |
| `scheduler` | One large CPU-bound placement process | 1460 |

```
make PROFILE=worker build
make validate-all          # every profile x every kernel track
```

## Why separate kernels

The layers fail differently, so they should be attacked differently.

**hypervisor** is the only layer that runs guest VMs, so it is the only one
that needs KVM's full surface, vhost, VFIO/iommufd device assignment, and
SEV/TDX. That is roughly 1.5 MiB of code plus the entire device-assignment
uAPI. Every other layer carrying it is running an attack surface for a
capability it never uses.

**worker** runs other people's code, which makes it the most exposed layer.
It needs the container enforcement stack (cgroup v2 io/cpu/memory controllers,
PSI, RDT cache partitioning) and it needs KVM — but only KVM, for gVisor's
KVM platform and microVM sandboxes. No VFIO, no SEV: a worker node hands out
sandboxes, not hardware. `X86_CPU_RESCTRL` matters here specifically: without
cache partitioning a batch task evicts a latency-sensitive task's working set
from L3 and no cgroup setting will stop it.

**control-plane** is a replicated state machine whose commit path is an fsync
barrier. A stall there is a leader election, and a leader election is a
cell-wide event. It needs no virtualization at all, and its risk is not
throughput but tail latency and blast radius.

**scheduler** is one enormous long-lived process running a CPU-bound placement
loop over the whole cluster's state. No local durability, no guests, no
containers to isolate. Its kernel's job is to stay out of the way of a
multi-hundred-GB heap: TLB reach, NUMA page placement, and profiling.

## What each layer deliberately does not get

| | hypervisor | worker | control-plane | scheduler |
|---|---|---|---|---|
| KVM | full + SEV/TDX | KVM only | — | — |
| VFIO / device assignment | yes | — | — | — |
| Container enforcement | — | full | basic | — |
| `IP_VS` service networking | — | yes | — | — |
| dm-crypt scratch | yes | yes | — | — |
| Free-time poisoning (KSPP) | relaxed | on | on | on |

The one place a layer relaxes hardening is the hypervisor's
`opt-datapath-perf`, which turns off `INIT_ON_FREE_DEFAULT_ON` because
free-time poisoning is measurable on allocation-heavy paths like vhost-net.
Alloc-time init stays on everywhere.

## Adding a layer

Write `configs/fragments/layer-<name>.config` containing only what makes that
role different, and `profiles/<name>.profile` naming it. Then run
`make validate-all` — a layer that does not resolve on both kernel tracks is
not done.
