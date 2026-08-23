#!/bin/sh
# The POSITIVE half of the update-signature chain (the negative -- unsigned ->
# EPERM -- is already proven by `make smoke`).  Here:
#   1. build a hypervisor whose built-in trusted keyring holds our dev CA
#      (opt-trustkey) with KEXEC_SIG on (platform-metal);
#   2. sbsign a bzImage with the matching key;
#   3. embed THAT as the kexec probe target and boot.  The running kernel
#      should verify the signature against its baked-in key and ACCEPT it
#      (kexec-policy: loaded), where an unsigned image gets EPERM.
set -eu
cd "$(dirname "$0")/.."
OUT=out ./scripts/pki-init.sh
echo "==> building trust-anchored hypervisor"
make PROFILE=hypervisor KVMHOST_EXTRA="opt-trustkey opt-lowmem" build >/dev/null
echo "==> signing a kexec target with the dev db key"
docker run --rm -v "$PWD/out":/out kvmhost-build \
	sbsign --key /out/pki/secureboot.key --cert /out/pki/secureboot.crt \
		--output /out/bzImage-signed /out/bzImage-hypervisor >/dev/null 2>&1
echo "==> initramfs embedding the SIGNED image as the probe target"
docker run --rm -v kvmhost-src:/build -v "$PWD":/repo:ro -v "$PWD/out":/out \
	-e KVMHOST_ARCH=x86_64 -e PROBE_KERNEL=bzImage-signed \
	kvmhost-build /repo/scripts/mkinitramfs.sh >/dev/null
echo "==> booting; PID 1 kexec_file_loads the SIGNED image, expecting acceptance"
PROBE_KERNEL=bzImage-signed KEXEC_WANT=loaded EXPECT=host TIMEOUT=900 \
	MACHINE=q35 KVER=$(sed -n 's/^KERNEL_VERSION=//p' configs/kernel.pin) LUO_FLOOR=99 \
	./scripts/qemu-smoke.sh out/bzImage-hypervisor out/initramfs-x86_64.cpio.gz
