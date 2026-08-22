# Taking a new kernel

Three tiers. A fleet needs all three, because "reboot the machine" does not
scale to a CVE with a 24-hour SLA and does not survive a workload that cannot
be moved.

## Tier 1 — live patch a function (seconds, no disruption)

`KVMHOST_EXTRA=opt-livepatch`. kpatch/klp redirects a patched function via
ftrace. Good for a single-function security fix.

**This reverses the no-modules stance**, and that is the whole decision: a
live patch is delivered as a kernel module, so enabling livepatch brings the
module loader back. It is only defensible with `MODULE_SIG_FORCE` (set in the
fragment), lockdown in integrity mode (set in `50-security.config`), and the
signing key held offline.

The honest framing of the trade:

- without livepatch: every kernel fix is a reboot, so urgent fixes queue
  behind drain campaigns and machines run known-vulnerable for days;
- with livepatch: the module loader exists again, and signature enforcement is
  the only thing between an attacker with root and kernel code execution.

Layers differ here. `control-plane` has three to five replicas and can fail over
in seconds — rebooting one is cheap, so livepatch buys little and costs the
module loader. `hypervisor` and `worker` carry workloads that cannot be
moved cheaply, and that is where it earns its keep.

## Tier 2 — kexec with handover (KHO), ~1s, workloads survive

`70-liveupdate.config`, on by default in every profile. KHO passes memory and
metadata to the next kernel across a `kexec_file_load`, so the new kernel
comes up with the old kernel's preserved state instead of a blank machine.

On **7.2** this includes the Live Update Orchestrator (`LIVEUPDATE`,
`LIVEUPDATE_MEMFD`): memfd-backed memory — which is where a VMM keeps guest
RAM — and supported devices are handed over, so guests keep running across a
host kernel upgrade.

On **6.18 LTS** you get KHO but no LUO: `kernel/liveupdate/` does not exist on
that track. Memory can be preserved; live devices cannot be handed over.

There is a second LTS-only conflict worth knowing about: 6.18's KHO carries
`depends on !DEFERRED_STRUCT_PAGE_INIT`, so on that track fast boot and live
update are mutually exclusive. `kver-6.18.config` chooses live update, on the
grounds that a fleet that can kexec-with-handover rarely cold-boots. 7.2
dropped the restriction and gets both.

Both tracks use `kexec_file_load` only. The old `kexec_load` syscall takes an
unverified image from userspace; lockdown refuses it, and so do we.

## Tier 3 — drain and reboot

Always works, always available, and the thing the other two tiers exist to
avoid. Enable `KEXEC_SIG` and enroll your CA before any of this runs in
production: an unsigned kexec image is a kernel-replacement primitive.

## Which tier for which layer

| Layer | Default | Why |
|---|---|---|
| `hypervisor` | KHO + LUO | Guests cannot be evacuated cheaply; live migration of every VM is a multi-hour campaign per host |
| `worker` | KHO + LUO | Tasks can be rescheduled, but not for free at fleet scale |
| `control-plane` | drain + kexec | Replicas fail over in seconds; simplicity beats preserved state |
| `scheduler` | drain + kexec | Rebuilds its in-memory state from the control plane on start |
