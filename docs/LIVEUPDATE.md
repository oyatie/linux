# Taking a new kernel

**v1 (LTS track): drain + `kexec_file_load`, plus livepatch on VFIO hosts.**
**Destination (7.x track): kexec-with-handover, where a host kernel update
becomes ~1s of blackout with guest memory preserved.**

The tiers below describe the full machinery; which tier a machine gets is
decided by `LIVEUPDATE=yes` in its profile and the `LUO_FLOOR` gate in
`build.sh` — guests never compile any of it, because a guest is replaced, not
handed over.

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

## Does live update make livepatch unnecessary?

No -- and the reason is verifiable rather than a matter of taste. In the whole
of 7.2 there is **exactly one** LUO file handler:

```
$ grep -rn liveupdate_register_file_handler --include=*.c .
./mm/memfd_luo.c:611:   int err = liveupdate_register_file_handler(&memfd_luo_handler);
```

memfd. Nothing else. Which produces a different answer per layer:

**hypervisor — livepatch still required.** LUO hands over memfd-backed memory,
which is where a VMM keeps guest RAM, so a pure-virtio guest can in principle
survive a kexec. An *assigned device* cannot: there is no vfio or iommufd
handover path in this kernel. Every SR-IOV or passthrough guest on the host
dies across the kexec. Since device assignment is a large part of why this
layer exists, live update does not cover its fleet-wide CVE problem.

**worker — livepatch required for a different reason.** LUO preserves memory
*objects*, not *processes*. kexec restarts the kernel; every tenant task on the
node dies regardless of what was handed over. For a container host, live update
buys nothing at all — the node has to be drained either way.

**control-plane, scheduler — neither is needed.** Replicas fail over in
seconds, so drain-and-reboot is the correct tool and the module loader stays
out of the image.

**When you can drop livepatch:** a hypervisor fleet running only virtio-backed
guests, with a VMM that implements the LUO session/restore protocol. That
combination genuinely is covered by tier 2, and dropping `opt-livepatch` from
the profile is then strictly better -- it removes the module loader. It is a
one-line change in `profiles/hypervisor.profile`, and it is the right change
to make the day your fleet stops doing passthrough, or the day LUO grows a
vfio handler.

The two tiers are also not substitutes in the other direction: livepatch
cannot fix a data-structure change, an init-time bug, or anything needing new
code paths, and kexec can. A fleet wants both.

## Which tier for which layer

| SKU | v1 (LTS) | Destination (7.x) |
|---|---|---|
| `hypervisor` / `gpu-node` | drain + kexec_file_load; **livepatch** for CVEs on VFIO hosts (passthrough guests cannot be evacuated) | KHO + LUO for virtio-backed guests; livepatch stays until LUO grows a vfio handler |
| `hypervisor-dpu` | same as hypervisor | same |
| `trusted-compute` | drain + kexec (first-party services are drainable; no module loader) | same |
| guests (`ch-guest`, `fc-guest`, `ch-guest-k8s`) | replaced, never upgraded in place — no kexec, no KHO, no livepatch compiled in | same |
