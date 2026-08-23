#!/bin/sh
# Exercise real hardware DRIVER paths against QEMU-emulated devices (TCG, no
# KVM): NVMe, Intel IOMMU (VT-d), multi-node NUMA, and an Intel NIC (igb).
# This is functional coverage -- the driver binds and the device works -- NOT
# performance (TCG timings are meaningless) and NOT the datacenter NICs QEMU
# cannot model (mlx5/ice/bnxt).  Build the kernel with KVMHOST_NICS=intel so
# the emulated igb has a driver.
#
#   hw-smoke.sh <bzImage> <initramfs>
set -eu
cd "$(dirname "$0")/.."
K=${1:?bzImage}; I=${2:?initramfs}
OUT=out
nvme=$(mktemp); dd if=/dev/zero of="$nvme" bs=1M count=64 status=none
LOG=$(mktemp)

qemu-system-x86_64 -machine q35,accel=tcg -cpu max -m 1536 -nographic -no-reboot \
	-kernel "$K" -initrd "$I" \
	-append "console=ttyS0 panic=1 rdinit=/init intel_iommu=on kvmhost.hw=1 kvmhost.expect=host kvmhost.kexec=eperm kvmhost.luo=absent" \
	-device intel-iommu,intremap=on \
	-smp 4 -numa node,cpus=0-1,memdev=m0 -numa node,cpus=2-3,memdev=m1 \
	-object memory-backend-ram,id=m0,size=768M -object memory-backend-ram,id=m1,size=768M \
	-drive file="$nvme",if=none,id=nv0,format=raw -device nvme,drive=nv0,serial=deadbeef \
	-device igb,netdev=n0 -netdev user,id=n0 \
	>"$LOG" 2>&1 &
qp=$!; w=0
while kill -0 "$qp" 2>/dev/null; do
	grep -qE "KVMHOST SMOKE-(OK|FAIL)" "$LOG" && { sleep 1; break; }
	[ "$w" -ge 600 ] && break; sleep 3; w=$((w+3))
done
kill "$qp" 2>/dev/null || true; wait "$qp" 2>/dev/null || true
rm -f "$nvme"

echo "=== hardware driver probes (emulated devices, TCG):"
grep -E "KVMHOST (ok|FAIL)|SMOKE-" "$LOG" | grep -iE "nvme|iommu|numa|igb|SMOKE" || true
grep -q "KVMHOST SMOKE-OK" "$LOG" && echo "==> PASS: NVMe, VT-d IOMMU, NUMA, Intel NIC drivers all bound" ||
	{ echo "==> FAIL; tail:"; tail -25 "$LOG"; exit 1; }
