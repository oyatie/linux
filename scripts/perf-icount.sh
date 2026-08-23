#!/bin/sh
# Deterministic, hardware-agnostic boot-cost metric: under -icount the guest
# clock advances by executed instructions, so a boot milestone's timestamp is
# instruction-proportional and identical run-to-run (with nokaslr).  A config
# change that adds real work moves it beyond the ~us TCG-warmup noise -- a CI
# perf-regression signal that needs no real CPU.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/out":/out kvmhost-build sh -c '
for run in 1 2 3; do
  ts=$(timeout 240 qemu-system-x86_64 -machine q35,accel=tcg -icount shift=1,sleep=off \
    -m 1024 -nographic -no-reboot -kernel /out/bzImage-fc-guest \
    -initrd /out/initramfs-x86_64.cpio.gz \
    -append "console=ttyS0 panic=1 printk.time=1 nokaslr rdinit=/init kvmhost.expect=guest kvmhost.kexec=enosys kvmhost.luo=absent" 2>/dev/null \
    | grep -aoE "^\[[ ]*[0-9]+\.[0-9]+\] Run /init" | grep -oE "[0-9]+\.[0-9]+" | head -1)
  echo "  run $run: instruction-proportional virt-time to /init = ${ts}s"
done'
echo "==> deterministic across runs (KASLR off); a regression shifts this beyond ~us noise"
