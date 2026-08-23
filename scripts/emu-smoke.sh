#!/bin/sh
# One-shot boot of a kernel under QEMU (TCG) exercising an emulation feature
# selected by a kvmhost.<flag> probe in the init.  Usage:
#   emu-smoke.sh <kernel> <flag> [extra qemu args...]
set -eu
cd "$(dirname "$0")/.."
K=$1 FLAG=$2; shift 2
docker run --rm -v kvmhost-src:/build -v "$PWD":/repo:ro -v "$PWD/out":/out \
	-e KVMHOST_ARCH=x86_64 -e PROBE_KERNEL=bzImage-hypervisor kvmhost-build \
	/repo/scripts/mkinitramfs.sh >/dev/null 2>&1
LOG=$(mktemp)
docker run --rm -v "$PWD/out":/out kvmhost-build sh -c "
timeout 300 qemu-system-x86_64 -machine q35,accel=tcg -m 1024 -nographic -no-reboot \
  -kernel /out/$K -initrd /out/initramfs-x86_64.cpio.gz \
  -append 'console=ttyS0 panic=1 rdinit=/init $FLAG kvmhost.expect=host kvmhost.kexec=eperm kvmhost.luo=absent' \
  $* 2>&1" >"$LOG" 2>&1
grep -E 'KVMHOST (ok|FAIL)|SMOKE-' "$LOG"
grep -q 'KVMHOST SMOKE-OK' "$LOG" && echo "==> PASS" || { echo "==> FAIL"; tail -15 "$LOG"; exit 1; }
