#!/bin/sh
# Boot out/vmlinux-fc-guest under REAL Firecracker and assert on it.
#
# QEMU's microvm machine is a faithful stand-in for CI on machines without
# KVM (make smoke PROFILE=fc-guest uses it), but it is a stand-in: only this
# script proves the artifact against the actual plant VMM -- ELF loading, the
# FC boot protocol, and virtio-mmio devices declared on the command line.
# Requires: Linux, /dev/kvm, firecracker in PATH.
set -eu

KERNEL=${1:-out/vmlinux-fc-guest}
INITRD=${2:-out/initramfs.cpio.gz}

[ "$(uname -s)" = "Linux" ] || { echo "fc-smoke: needs Linux (have $(uname -s)); use 'make smoke PROFILE=fc-guest' as the QEMU stand-in" >&2; exit 2; }
[ -e /dev/kvm ] || { echo "fc-smoke: /dev/kvm not available" >&2; exit 2; }
command -v firecracker >/dev/null || { echo "fc-smoke: firecracker not in PATH" >&2; exit 2; }
[ -f "$KERNEL" ] || { echo "fc-smoke: $KERNEL missing -- make PROFILE=fc-guest build" >&2; exit 2; }

sock=$(mktemp -u)
log=$(mktemp)
cfg=$(mktemp)
cat >"$cfg" <<JSON
{
  "boot-source": {
    "kernel_image_path": "$KERNEL",
    "initrd_path": "$INITRD",
    "boot_args": "console=ttyS0 panic=1 rdinit=/init printk.time=1 kvmhost.expect=guest"
  },
  "machine-config": { "vcpu_count": 2, "mem_size_mib": 512 }
}
JSON
timeout 120 firecracker --api-sock "$sock" --config-file "$cfg" >"$log" 2>&1 || true
grep -E "^KVMHOST " "$log" || true
if grep -q "KVMHOST SMOKE-OK" "$log"; then
	echo "==> PASS under real Firecracker"
else
	echo "==> FAIL; last lines:" >&2; tail -30 "$log" >&2; exit 1
fi
