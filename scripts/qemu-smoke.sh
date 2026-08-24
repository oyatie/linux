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
# On arm64 everything boots the `virt` machine, and on an Apple-silicon host
# QEMU can use HVF -- so arm64 smokes run hardware-accelerated, not emulated.
MACHINE=${MACHINE:-q35}
KARCH=${KARCH:-x86_64}
QEMU=qemu-system-x86_64
CONSOLE=ttyS0
ACCEL=""
if [ "$KARCH" = "arm64" ]; then
	QEMU=qemu-system-aarch64
	MACHINE=virt
	CONSOLE=ttyAMA0
	CPU="cortex-a76"
	if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
		ACCEL="-accel hvf"
		CPU=host
	fi
	# A host-expect kernel must prove /dev/kvm, and arm64 KVM initialises
	# only when the kernel is entered at EL2.  HVF gives the guest EL1, so
	# for host kernels we trade acceleration for TCG's virtualization=on,
	# which emulates EL2.  Guest kernels keep HVF and its ~20x speedup.
	if [ "${EXPECT:-host}" = "host" ]; then
		MACHINE="virt,virtualization=on"
		ACCEL=""
		CPU=max
	fi
fi
LOG=$(mktemp)

# Expectation flags for the init's assertions.
#   kexec: guests have no syscall (enosys); hosts must be policy-gated (eperm)
#          unless the caller overrides to record a known gap.
#   luo:   required on host kernels at/above the LUO floor, absent otherwise.
EXPECT=${EXPECT:-host}
if [ -z "${KEXEC_WANT:-}" ]; then
	[ "$EXPECT" = "guest" ] && KEXEC_WANT=enosys || KEXEC_WANT=eperm
fi
# LUO is compiled only when the profile set LIVEUPDATE=yes AND the kernel is
# >= floor -- the resolved .config is the source of truth, so read it rather
# than assume from version alone (trusted-compute/workstation are hosts that do
# NOT ship LUO, and would false-fail a version-only expectation).  Config name
# mirrors build.sh: strip only the bzImage/Image prefix, keep any -arch/-dst.
LUO_WANT=absent
_luocfg="out/$(basename "$BZIMAGE" | sed -E 's/^(bzImage|Image)-//').config"
if [ "$EXPECT" = "host" ] && [ -f "$_luocfg" ] && grep -q '^CONFIG_LIVEUPDATE=y' "$_luocfg"; then
	LUO_WANT=required
fi

echo "==> booting $BZIMAGE under QEMU (timeout ${TIMEOUT}s)"
$QEMU \
	-machine "$MACHINE" \
	$ACCEL \
	-cpu "${CPU:-max}" \
	-smp 2 \
	-m 1024 \
	-nographic \
	-no-reboot \
	-kernel "$BZIMAGE" \
	-initrd "$INITRD" \
	-append "console=$CONSOLE panic=1 rdinit=/init printk.time=1 kvmhost.expect=$EXPECT kvmhost.kexec=$KEXEC_WANT kvmhost.luo=$LUO_WANT${LUO_WANT:+ }$([ "$LUO_WANT" = required ] && echo liveupdate=on)" \
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
