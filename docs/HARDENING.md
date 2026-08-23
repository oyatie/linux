# Hardening audit

Independent scoring by [kernel-hardening-checker][khc] (KSPP + CLIP OS + grsec
+ lockdown recommendation sets) against the resolved configs. Run it yourself:

```
make hardening PROFILE=hypervisor
```

[khc]: https://github.com/a13xp0p0v/kernel-hardening-checker

## Scores (v1 track)

| Profile | OK | FAIL |
|---|---|---|
| `fc-guest` | 211 | 48 |
| `hypervisor` | 208 | 51 |
| `ch-guest` | 201 | 58 |
| `trusted-compute` | 196 | 63 |

`trusted-compute` scoring *lowest* is not a regression — it enables
`IOMMU_DEFAULT_PASSTHROUGH` (untranslated DMA for first-party workloads), which
is the entire point of that SKU and exactly what a hardening checker is
supposed to flag. The score measures conformance to a generic desktop/endpoint
profile, not fitness for purpose; the divergences below are the design.

## What the audit fixed

The first run (196/63 on hypervisor) surfaced twelve real gaps, now closed —
several were defaults left on the table, one was an outright miss:

| Symbol | Was | Now | Why it mattered |
|---|---|---|---|
| `SYN_COOKIES` | off | **on** | SYN-flood defense, off on a networked host — an outright miss |
| `ARCH_MMAP_RND_BITS` | 28 | **32** (x86) / 33 (arm64) | ASLR entropy left below the arch ceiling |
| `DEFAULT_MMAP_MIN_ADDR` | 4096 | **65536** | raise the NULL-deref exploitation floor |
| `RANDOM_KMALLOC_CACHES` | off | **on** | anti heap-spray |
| `SLAB_BUCKETS` | off | **on** | separate usercopy buckets, anti cross-cache |
| `PAGE_TABLE_CHECK[_ENFORCED]` | off | **on** | PTE integrity — the page tables *are* the hypervisor's asset |
| `KFENCE` | off | **on** | production-grade sampling UAF/OOB detector (unlike KASAN) |
| `MITIGATION_SLS` | off | **on** | straight-line-speculation hardening |
| `EFI_DISABLE_PCI_DMA` | off | **on** (metal) | close the pre-IOMMU DMA-attack window at boot |
| `PROC_MEM_NO_FORCE` | default | **on** | `/proc/pid/mem` writes only via ptrace |

## The remaining ~51 FAILs are deliberate, in six groups

**1. Observability is a design pillar.** grsec/a13xp0p0v want ftrace, kprobes,
uprobes, `STACK_TRACER`, `HIST_TRIGGERS`, `BLK_DEV_IO_TRACE`, `PROC_PAGE_MONITOR`,
`DEBUG_FS` all off. A fleet you cannot introspect at 3am is a worse outcome
than the surface these add. Kept.

**2. The VMM datapath and runtime ABI need them.** `AIO`, `IO_URING`, `TLS`
(kTLS), `KCMP`, `RSEQ`, `CACHESTAT_SYSCALL`, `USERFAULTFD` (live migration),
`BPF_SYSCALL` (host tooling). Removing these breaks Cloud Hypervisor /
Firecracker or the runtime. `USERFAULTFD` *is* stripped on guests, where it has
no user.

**3. kdump and live update are design pillars.** `CRASH_DUMP`, `KEXEC_FILE`,
`PROC_VMCORE`, `LIVEPATCH`, `MODULES`. CLIP/KSPP want a monolithic
no-kexec kernel; our whole update-and-postmortem story is built on these.
`MODULES`/`LIVEPATCH` are host-only and signature-enforced.

**4. Diagnostics.** `KALLSYMS`, `COREDUMP`, `INET_DIAG`. `COREDUMP` ships with
`fs.suid_dumpable=0` and `RLIMIT_CORE=0` (a VMM core dump *is* guest memory).

**5. GCC, not clang — the one worth revisiting.** `CFI_CLANG`,
`CFI_PERMISSIVE`, `UBSAN_BOUNDS`/`_TRAP`/`_LOCAL_BOUNDS`/`_SANITIZE_ALL`,
`RANDSTRUCT_FULL`, `GCC_PLUGIN_LATENT_ENTROPY`, `KSTACK_ERASE` are clang-only or
need `gcc-*-plugin-dev` (absent in the toolchain image). Kernel Control-Flow
Integrity is the biggest single item this leaves on the table, and a clang
(`LLVM=1`) build is the documented path to it — several hyperscalers build
their host kernels with clang for exactly this. It is a real future direction,
not a settled decision.

**6. Threat-model divergences we make on purpose.**
- `INTEL_IOMMU_SVM` — the checker wants it on; we keep it **off** (SVM hands a
  device the CPU page tables, which is wrong for tenant passthrough).
- `INIT_ON_FREE_DEFAULT_ON` — on everywhere except the hypervisor datapath
  (`opt-datapath-perf`), where free-poisoning is measurable on vhost-net.
- `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` — we use *integrity* lockdown, not
  confidentiality; the latter breaks kdump reads and perf, which pillar 1 and 3
  depend on.
- `MITIGATION_CALL_DEPTH_TRACKING` — off deliberately (Skylake-era throughput).
- `TRIM_UNUSED_KSYMS` — conflicts with livepatch, which needs the symbols.
- `SECURITY_SELINUX_BOOTPARAM` — kept as an operational escape hatch.

## Not adopted, but on the table

`RESET_ATTACK_MITIGATION` (wipe RAM on dirty reboot, anti cold-boot) is
defensible for confidential-compute SKUs but costs reboot time fleet-wide;
a candidate for a `trusted-compute`/SEV overlay rather than the base.
