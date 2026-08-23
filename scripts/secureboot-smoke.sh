#!/bin/sh
# Prove UEFI Secure Boot ENFORCEMENT, not just that we can sign: enroll our dev
# CA as PK/KEK/db into OVMF, then show the firmware LAUNCHES a correctly-signed
# UKI and REFUSES a tampered one.  Runs entirely in-container (Debian OVMF +
# qemu TCG), so it needs no host firmware and no KVM.
#
#   secureboot-smoke.sh <kernel-with-EFI-stub>
set -eu
OUT=${OUT:-/out}
K=${1:?kernel image (must have CONFIG_EFI_STUB)}
W=$(mktemp -d)

# The kernel is already an x86_64 EFI application (CONFIG_EFI_STUB); sign it
# directly.  (A full systemd-stub UKI would embed cmdline+initrd, but Debian's
# arm64 systemd-boot-efi ships only the aa64 stub, which would stamp the PE
# aarch64 -- x86 OVMF rightly rejects that as "Unsupported".  Signing the
# native x86_64 EFI-stub kernel avoids the cross-arch stub entirely; it still
# prints EFI-stub/decompress output when launched, which is what this proves.)
echo "==> signing the x86_64 EFI-stub kernel with the dev db key"
sbsign --key "$OUT/pki/secureboot.key" --cert "$OUT/pki/secureboot.crt" \
	--output "$W/uki.efi" "$K" >/dev/null 2>&1
sbverify --cert "$OUT/pki/secureboot.crt" "$W/uki.efi" >/dev/null && echo "    signature: valid"

echo "==> enrolling dev CA (PK/KEK/db) into OVMF vars, secure boot ON"
virt-fw-vars -i /usr/share/OVMF/OVMF_VARS_4M.fd -o "$W/vars.fd" \
	--set-pk  "$(uuidgen)" "$OUT/pki/secureboot.crt" \
	--add-kek "$(uuidgen)" "$OUT/pki/secureboot.crt" \
	--add-db  "$(uuidgen)" "$OUT/pki/secureboot.crt" \
	--secure-boot >/dev/null 2>&1

mk_esp() { # $1=uki $2=out.img
	dd if=/dev/zero of="$2" bs=1M count=64 status=none
	mkfs.vfat "$2" >/dev/null
	mmd -i "$2" ::/EFI ::/EFI/BOOT
	mcopy -i "$2" "$1" ::/EFI/BOOT/BOOTX64.EFI
}
run() { # $1=esp -> stdout log; returns qemu
	timeout 180 qemu-system-x86_64 -machine q35 -m 1024 -nographic -no-reboot \
		-global ICH9-LPC.disable_s3=1 \
		-drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd,readonly=on \
		-drive if=pflash,format=raw,unit=1,file="$W/vars.fd.run" \
		-drive format=raw,file="$1" 2>&1 || true
}

echo
echo "=== TEST 1: correctly-signed UKI (expect: Secure Boot launches it) ==="
mk_esp "$W/uki.efi" "$W/good.img"
cp "$W/vars.fd" "$W/vars.fd.run"
run "$W/good.img" | tee "$OUT/sb-good.log" | grep -iE "KVMHOST|EFI stub|Linux version|Decompress|Security Violation|Access Denied|verification fail" | head -8 || true
# PASS = firmware LAUNCHED our signed image (kernel/stub ran) and did NOT deny.
good=FAIL
if grep -qiE "EFI stub|Linux version|Decompress|x86/microcode|Kernel|setup_percpu" "$OUT/sb-good.log" && \
   ! grep -qiE "Access Denied|Security Violation" "$OUT/sb-good.log"; then good=PASS; fi

echo
echo "=== TEST 2: tampered UKI (1 byte flipped after signing; expect: REFUSED) ==="
cp "$W/uki.efi" "$W/bad.efi"
# corrupt a byte in the middle of the signed image -> signature no longer valid
printf '\xff' | dd of="$W/bad.efi" bs=1 seek=$(( $(stat -c %s "$W/bad.efi") / 2 )) count=1 conv=notrunc status=none
mk_esp "$W/bad.efi" "$W/bad.img"
cp "$W/vars.fd" "$W/vars.fd.run"
run "$W/bad.img" | tee "$OUT/sb-bad.log" | grep -iE "KVMHOST|Security Violation|Access Denied|verification fail|start_image" | head -6 || true
bad=FAIL; grep -qiE "Security Violation|Access Denied|verification fail" "$OUT/sb-bad.log" && bad=PASS
grep -qiE "EFI stub|Linux version|KVMHOST" "$OUT/sb-bad.log" && bad="FAIL (tampered image LAUNCHED!)"

echo
echo "==> signed UKI:   $good (firmware launched our signed image)"
echo "==> tampered UKI: $bad (firmware refused the tampered image)"
# logs preserved in $OUT/sb-good.log, $OUT/sb-bad.log
rm -rf "$W"
[ "$good" = PASS ] && [ "$bad" = PASS ]
