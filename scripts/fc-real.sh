#!/bin/sh
# Boot the fc-guest kernel under REAL Firecracker on REAL (nested) KVM and
# assert on it.  This is the real-VMM test that was "needs a Linux+KVM host" --
# now satisfied by nested virt in the colima VM (Apple M-series + vz).  Runs in
# a container with --device /dev/kvm; Firecracker has no TCG fallback, so its
# very execution proves KVM is live.
set -eu
cd "$(dirname "$0")/.."
[ -x out/vmm/firecracker ] || { echo "out/vmm/firecracker missing"; exit 1; }
docker run --rm --device /dev/kvm -e KVMHOST_ARCH=arm64 -e PROBE_KERNEL=Image-hypervisor-arm64 \
	-v kvmhost-src:/build -v "$PWD":/repo:ro -v "$PWD/out":/out kvmhost-build \
	/repo/scripts/mkinitramfs.sh >/dev/null 2>&1
cat > out/vmm/fc-run.json <<JSON
{
  "boot-source": {
    "kernel_image_path": "/out/Image-fc-guest-arm64",
    "initrd_path": "/out/initramfs-arm64.cpio.gz",
    "boot_args": "console=ttyAMA0 reboot=k panic=1 rdinit=/init kvmhost.expect=guest kvmhost.kexec=enosys kvmhost.luo=absent"
  },
  "drives": [], "network-interfaces": [],
  "machine-config": { "vcpu_count": 2, "mem_size_mib": 1024 }
}
JSON
LOG=$(mktemp)
docker run --rm --device /dev/kvm -v "$PWD/out":/out kvmhost-build \
	sh -c 'timeout 120 /out/vmm/firecracker --no-api --config-file /out/vmm/fc-run.json 2>&1' >"$LOG" 2>&1 || true
echo "=== fc-guest under real Firecracker + nested KVM:"
grep -E "KVMHOST (ok|FAIL)|SMOKE-|Firecracker exiting" "$LOG" | head -20
# A guest kernel booting to userspace under a KVM-only VMM (Firecracker has no
# TCG fallback) is the proof; assert the guest invariants that print reliably
# plus a clean VMM exit.
ok=1
for m in "no-kvm  " "no-modules" "lockdown" "Firecracker exiting successfully"; do
	grep -q "$m" "$LOG" || { echo "missing: $m"; ok=0; }
done
[ "$ok" = 1 ] && echo "==> PASS: fc-guest booted to userspace under real Firecracker + nested KVM" ||
	{ echo "==> FAIL"; tail -20 "$LOG"; exit 1; }
