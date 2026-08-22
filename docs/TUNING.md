# Tuning

Policy that deliberately lives outside the image. Anything you might need to
change without rebuilding and requalifying a kernel belongs on the command
line or in a sysctl, not in a fragment.

## Boot command line

A reasonable starting point for a 2-socket host, with the reasoning inline.
Numbers assume 128 threads; adjust the CPU lists to your topology.

```
console=ttyS0,115200n8 earlycon
# Housekeeping CPUs 0-7 take timers, RCU callbacks, IRQs and the host agent.
# Everything else runs vCPU threads with no tick and no RCU work.
isolcpus=managed_irq,domain,8-127
nohz_full=8-127
rcu_nocbs=8-127
irqaffinity=0-7
# Guest memory. 1G pages: lower TLB pressure and no THP compaction stalls in
# the fault path of a running guest.
default_hugepagesz=1G hugepagesz=1G hugepages=<N>
transparent_hugepage=madvise
# IOMMU. Strict is the build default; passthrough of the host's own devices
# is what iommu.passthrough covers, and it is NOT safe with assigned devices.
intel_iommu=on amd_iommu=on iommu=nopt
# Crash path.
crashkernel=512M-:768M
panic=30 panic_on_warn=0
# RAS: let the kernel offline pages on corrected-error thresholds.
mce=recovery
# Entropy.
random.trust_cpu=on random.trust_bootloader=on
```

`RANDOM_TRUST_CPU`/`RANDOM_TRUST_BOOTLOADER` used to be build options; they
are runtime parameters now, which is why they are not in any fragment.

### SMT and mitigations

The single most consequential fleet decision, and the reason every mitigation
is compiled in rather than compiled out:

- **Multi-tenant, untrusted guests:** keep every mitigation at its default and
  use core scheduling (`SCHED_CORE`, built in) so SMT siblings only ever run
  one trust domain. Fall back to `nosmt` only if the workload cannot tolerate
  the core-scheduling overhead — it costs roughly half the machine.
- **Single-tenant / dedicated hosts:** relaxing specific mitigations is
  defensible. Do it per-mitigation on the command line, never with
  `mitigations=off`, and record which fleets run relaxed.

## Sysctls

```
# Never trade guest latency for page cache.
vm.swappiness = 0
vm.overcommit_memory = 0
# NUMA balancing moves guest pages behind the VMM's back; pin instead.
kernel.numa_balancing = 0
# Fleet-wide crash policy: fail fast and produce a dump.
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
# BPF stays a host-agent tool.
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 1
# Networking for a host carrying tenant traffic.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
```

## NUMA and VM placement

Pin each VM's vCPU threads and its memory to a single node, and pin the VMM's
I/O threads to a housekeeping CPU on that same node. Assign VFs from a NIC on
the guest's node. `kernel.numa_balancing=0` is deliberate: the VMM knows the
topology it advertised to the guest, the kernel's balancer does not, and the
balancer will happily migrate pages out from under a pinned vCPU.

Check `SCHED_CORE` is actually in use (`/proc/PID/sched` core scheduling
cookies) rather than assuming it — enabling the config does nothing until the
VMM or the control plane sets a cookie per VM.

## Verifying a running host

```
grep -c . /proc/config.gz            # not available: no CONFIG_IKCONFIG here
cat /sys/kernel/security/lockdown    # expect [integrity]
cat /proc/sys/kernel/modules_disabled
cat /sys/devices/system/cpu/vulnerabilities/*
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages
ls /sys/class/iommu/                 # expect dmar*/ivhd* present
cat /sys/module/kvm_intel/parameters/nested   # expect N unless nesting is a product
```

`IKCONFIG` is deliberately not enabled — the shipped config is in
`out/kvmhost.config`, which is a build artifact you can attest against, rather
than something readable out of a running kernel by anything on the host.

## Live update

`KEXEC_FILE` and `CRASH_HOTPLUG` are here to support kexec-based host updates:
drain the host, `kexec_file_load` the next kernel, jump. Enable `KEXEC_SIG`
and enroll your CA before doing this in production — an unsigned kexec image
is a kernel-replacement primitive, and lockdown will refuse it anyway.
