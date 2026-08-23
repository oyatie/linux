#!/bin/sh
# End-to-end LUO handover: a SIGNED live update preserving a memfd across kexec.
# kernel A preserves "hello kexec world" via /dev/liveupdate, kexecs the signed
# next kernel in-place (host QEMU, TCG), kernel B restores and verifies it.
# Build steps run in the container; the boot runs on the host qemu (real RAM).
set -eu
cd "$(dirname "$0")/.."
OUT=out
K=$OUT/bzImage-hypervisor-dst
[ -f "$K" ] || { echo "need 7.2 trust-anchored hypervisor; see docs"; exit 1; }

echo "==> [container] sign kexec target, build test init + initramfs + /boot vfat"
docker run --rm -v "$PWD/out":/out -v "$PWD":/repo:ro kvmhost-build sh -ec '
OUT=/out
sbsign --key $OUT/pki/secureboot.key --cert $OUT/pki/secureboot.crt \
	--output $OUT/luo-kernel.signed $OUT/bzImage-hypervisor-dst >/dev/null 2>&1
x86_64-linux-gnu-gcc -static -Os -o /tmp/luo-init /repo/initramfs/luo-init.c
x86_64-linux-gnu-strip /tmp/luo-init
W=$(mktemp -d)
mkdir -p $W/root/proc $W/root/sys $W/root/dev $W/root/tmp $W/root/boot \
	 $W/root/sys/kernel/debug $W/root/sys/kernel/security
cp /tmp/luo-init $W/root/init
cp $OUT/luo_kexec_simple $W/root/luo_kexec_simple
(cd $W/root && find . | cpio -o -H newc --quiet | gzip -9) > $OUT/luo-initramfs.cpio.gz
dd if=/dev/zero of=$OUT/luo-boot.img bs=1M count=48 status=none
mkfs.vfat $OUT/luo-boot.img >/dev/null
mcopy -i $OUT/luo-boot.img $OUT/luo-kernel.signed ::/bzImage
mcopy -i $OUT/luo-boot.img $OUT/luo-initramfs.cpio.gz ::/initramfs
'
echo "==> [host] boot kernel A (preserve -> kexec -> verify)"
LOG=$(mktemp)
# macOS has no `timeout`; background qemu + poll for the verdict (like
# qemu-smoke.sh).  A kexec jump is not a QEMU-visible reset, so -no-reboot is
# safe and stops any accidental reboot loop; the final poweroff exits qemu.
qemu-system-x86_64 -machine q35 -cpu max -m 2048 -nographic -no-reboot \
	-kernel "$OUT/luo-kernel.signed" -initrd "$OUT/luo-initramfs.cpio.gz" \
	-drive format=raw,file="$OUT/luo-boot.img",if=virtio \
	-append "console=ttyS0 liveupdate=on rdinit=/init" >"$LOG" 2>&1 &
qp=$!
w=0
while kill -0 "$qp" 2>/dev/null; do
	grep -q "LUO-TEST: RESULT" "$LOG" && { sleep 2; break; }
	[ "$w" -ge 900 ] && break
	sleep 3; w=$((w+3))
done
kill "$qp" 2>/dev/null || true; wait "$qp" 2>/dev/null || true

grep -iE "LUO-TEST|STAGE [12]|hello kexec|KEXEC TEST PASSED|RESULT|kexec_file_load|Access Denied|SKIP|Kernel panic" "$LOG" | head -40
echo "--- full log: $LOG"
grep -q "LUO-TEST: RESULT PASS" "$LOG" && grep -q "KEXEC TEST PASSED" "$LOG" && \
	{ echo "==> PASS: memfd survived a signed kexec live-update"; exit 0; } || \
	{ echo "==> did not reach PASS (see log)"; exit 1; }
