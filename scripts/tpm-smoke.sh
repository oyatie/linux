#!/bin/sh
# Emulated TPM 2.0 (swtpm) behind tpm-crb: prove the TPM stack binds and a PCR
# bank is readable -- measured-boot plumbing without a hardware TPM.  In-
# container (swtpm + qemu-system-x86_64 TCG).
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v kvmhost-src:/build -v "$PWD":/repo:ro -v "$PWD/out":/out \
	-e KVMHOST_ARCH=x86_64 -e PROBE_KERNEL=bzImage-hypervisor kvmhost-build /repo/scripts/mkinitramfs.sh >/dev/null 2>&1
docker run --rm -v "$PWD/out":/out kvmhost-build sh -c '
set -e
S=$(mktemp -d)
swtpm socket --tpmstate dir=$S --ctrl type=unixio,path=$S/sock --tpm2 --daemon
sleep 1
timeout 300 qemu-system-x86_64 -machine q35,accel=tcg -m 1024 -nographic -no-reboot \
  -kernel /out/bzImage-hypervisor -initrd /out/initramfs-x86_64.cpio.gz \
  -append "console=ttyS0 panic=1 rdinit=/init kvmhost.tpm=1 kvmhost.expect=host kvmhost.kexec=eperm kvmhost.luo=absent" \
  -chardev socket,id=chrtpm,path=$S/sock -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 2>&1 | grep -iE "KVMHOST (ok|FAIL)|tpm|SMOKE-" | head -20
'
