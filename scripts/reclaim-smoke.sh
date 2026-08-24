#!/bin/sh
# Reclaim/sanitize kernel, end to end in QEMU: an emulated NVMe (crypto-erase +
# read-back verify), an swtpm-backed TPM (attestation anchor), and a RAM scrub
# -- the between-tenant decommission flow -- then ACPI poweroff.  Build of the
# init + the boot both run inside the container (qemu TCG + swtpm).
set -eu
cd "$(dirname "$0")/.."
OUT=out
[ -f "$OUT/bzImage-reclaim" ] || { echo "need $OUT/bzImage-reclaim -- run: make build PROFILE=reclaim" >&2; exit 1; }
LOG=$(mktemp)

echo "==> [container] build reclaim init + initramfs, seed a scratch NVMe, boot with swtpm"
docker run --rm -v "$PWD":/repo:ro -v "$PWD/out":/out kvmhost-build sh -ec '
OUT=/out
x86_64-linux-gnu-gcc -static -Os -Wall -o /tmp/reclaim-init /repo/initramfs/reclaim-init.c
x86_64-linux-gnu-strip /tmp/reclaim-init
W=$(mktemp -d); mkdir -p $W/root/proc $W/root/sys $W/root/dev $W/root/tmp
cp /tmp/reclaim-init $W/root/init
(cd $W/root && find . | cpio -o -H newc --quiet | gzip -9) > $OUT/reclaim-initramfs.cpio.gz
# a small "local instance NVMe" to prove erasure against
dd if=/dev/zero of=$OUT/reclaim-nvme.img bs=1M count=32 status=none
S=$(mktemp -d)
swtpm socket --tpmstate dir=$S --ctrl type=unixio,path=$S/sock --tpm2 --daemon
sleep 1
timeout 300 qemu-system-x86_64 -machine q35,accel=tcg -m 1024 -nographic -no-reboot \
  -kernel $OUT/bzImage-reclaim -initrd $OUT/reclaim-initramfs.cpio.gz \
  -drive file=$OUT/reclaim-nvme.img,if=none,id=nvm,format=raw \
  -device nvme,serial=BASALT0001,drive=nvm \
  -chardev socket,id=chrtpm,path=$S/sock -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -append "console=ttyS0 panic=1 rdinit=/init" 2>&1
' | tee "$LOG"

echo "----- reclaim report -----"
grep -iE "RECLAIM|nvme[0-9]|tpm" "$LOG" | grep -vi "kern  :" | head -40
echo "--- full log: $LOG"
grep -q "RECLAIM: RESULT PASS" "$LOG" && \
	{ echo "==> PASS: crypto-erase + RAM scrub + attestation anchor verified, box re-poolable"; exit 0; } || \
	{ echo "==> did not reach RESULT PASS (see log)"; exit 1; }
