#!/bin/sh
# Boot ch-guest under REAL Cloud Hypervisor on nested KVM.
set -eu
cd "$(dirname "$0")/.."
[ -x out/vmm/cloud-hypervisor ] || { echo "out/vmm/cloud-hypervisor missing"; exit 1; }
docker run --rm --device /dev/kvm -e KVMHOST_ARCH=arm64 -e PROBE_KERNEL=Image-hypervisor-arm64 \
	-v kvmhost-src:/build -v "$PWD":/repo:ro -v "$PWD/out":/out kvmhost-build \
	/repo/scripts/mkinitramfs.sh >/dev/null 2>&1
LOG=$(mktemp)
docker run --rm --device /dev/kvm -v "$PWD/out":/out kvmhost-build sh -c '
timeout 90 /out/vmm/cloud-hypervisor --kernel /out/Image-ch-guest-arm64 \
  --initramfs /out/initramfs-arm64.cpio.gz \
  --cmdline "console=ttyAMA0 reboot=k panic=1 rdinit=/init kvmhost.expect=guest" \
  --cpus boot=2 --memory size=1024M --serial tty --console off 2>&1' >"$LOG" 2>&1 || true
grep -E "KVMHOST (ok|FAIL)" "$LOG" | head
for m in "no-kvm  " "no-modules" "lockdown"; do grep -q "$m" "$LOG" || { echo "FAIL: missing $m"; exit 1; }; done
echo "==> PASS: ch-guest booted under real Cloud Hypervisor + nested KVM"
