#!/bin/sh
# Boot the built kernel and assert on what it reports about itself.
#
# On a host with KVM this is nearly instant; on a developer laptop it runs
# under TCG emulation, which is slow but still proves the boot path: EFI-less
# direct boot, serial console, devtmpfs, PID 1, and clean power-off.
set -eu

BZIMAGE=${1:?usage: qemu-smoke.sh <bzImage> <initramfs>}
INITRD=${2:?}
TIMEOUT=${TIMEOUT:-300}
# q35 for anything that expects PCI/ACPI; `microvm` for the MMIO-only guest,
# which has neither and must be booted by a VMM that speaks plain virtio-mmio.
MACHINE=${MACHINE:-q35}
LOG=$(mktemp)

echo "==> booting $BZIMAGE under QEMU (timeout ${TIMEOUT}s)"
qemu-system-x86_64 \
	-machine "$MACHINE" \
	-cpu max \
	-smp 2 \
	-m 1024 \
	-nographic \
	-no-reboot \
	-kernel "$BZIMAGE" \
	-initrd "$INITRD" \
	-append "console=ttyS0 panic=1 rdinit=/init printk.time=1 kvmhost.expect=${EXPECT:-host}" \
	>"$LOG" 2>&1 &
qemu_pid=$!

waited=0
while kill -0 "$qemu_pid" 2>/dev/null; do
	if grep -qE "KVMHOST SMOKE-(OK|FAIL)" "$LOG" 2>/dev/null; then break; fi
	if [ "$waited" -ge "$TIMEOUT" ]; then
		kill "$qemu_pid" 2>/dev/null || true
		echo "==> TIMEOUT after ${TIMEOUT}s; last 40 lines:" >&2
		tail -40 "$LOG" >&2
		exit 1
	fi
	sleep 2
	waited=$((waited + 2))
done
# An ACPI-less guest (fc-guest) cannot power off -- reboot() halts and QEMU
# stays resident -- so once the marker is in the log, the VM is done and we
# reap it ourselves instead of waiting on an exit that cannot come.
if kill -0 "$qemu_pid" 2>/dev/null; then
	kill "$qemu_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true

echo
grep -E "^KVMHOST |Linux version|Command line" "$LOG" || true
echo

if grep -q "KVMHOST SMOKE-FAIL" "$LOG"; then
	echo "==> FAIL: kernel booted but assertions did not hold:" >&2
	grep "KVMHOST FAIL" "$LOG" >&2
	exit 1
elif grep -q "KVMHOST SMOKE-OK" "$LOG"; then
	# A boot that reaches userspace but logs a BUG/oops is not a pass.
	if grep -qE "Kernel panic|BUG:|Oops:|WARNING:" "$LOG"; then
		echo "==> FAIL: reached userspace but the log contains a defect:" >&2
		grep -nE "Kernel panic|BUG:|Oops:|WARNING:" "$LOG" | head >&2
		exit 1
	fi
	# Time-to-userspace, from the kernel's own clock.  Under TCG emulation the
	# absolute number is meaningless -- it is inflated by whatever the host is
	# doing -- but it is directly comparable between two kernels booted the
	# same way, which is the question worth asking.
	ktime=$(grep -oE '^\[ *[0-9]+\.[0-9]+\]' "$LOG" | tail -1 | tr -d '[] ')
	printf '==> kernel time to last message: %ss (guest clock, TCG-inflated)\n' "${ktime:-?}"
	printf '==> wall clock to userspace:     %ss\n' "$waited"
	echo "==> PASS (full log: $LOG)"
else
	echo "==> FAIL: never reached userspace; last 40 lines:" >&2
	tail -40 "$LOG" >&2
	exit 1
fi
