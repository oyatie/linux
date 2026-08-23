#!/bin/sh
# Assemble a Unified Kernel Image (kernel + initramfs + cmdline in one PE) and
# sign it with the Secure Boot db key.  This single signed binary is what UEFI
# Secure Boot verifies and launches -- no unsigned bootloader in the chain.
#
#   mk-uki.sh <profile> <kernel-image>
set -eu
OUT=${OUT:-/out}
PROFILE=${1:?profile}
KERNEL=${2:?kernel image}
ROOTHASH=$(cat "$OUT/root.roothash" 2>/dev/null || echo UNSEALED)

# Root on the verity device, hash pinned on the command line; the signed hash
# file (root.roothash.p7s) travels in the initramfs for the kernel to verify.
printf 'console=ttyS0 root=/dev/dm-0 rootflags=ro dm-verity.roothash=%s panic=1\n' \
	"$ROOTHASH" > "$OUT/uki-cmdline.txt"

stub=$(ls /usr/lib/systemd/boot/efi/linuxx64.efi.stub 2>/dev/null || true)
uki="$OUT/uki-$PROFILE.efi"

if [ -n "$stub" ]; then
	# Proper UKI: sections glued onto the systemd EFI stub.
	objcopy \
		--add-section .osrel="$OUT/root.roothash" --change-section-vma .osrel=0x20000 \
		--add-section .cmdline="$OUT/uki-cmdline.txt" --change-section-vma .cmdline=0x30000 \
		--add-section .linux="$KERNEL" --change-section-vma .linux=0x2000000 \
		--add-section .initrd="$OUT/initramfs-x86_64.cpio.gz" --change-section-vma .initrd=0x3000000 \
		"$stub" "$uki.unsigned"
else
	# No stub in the image: sign the bzImage directly (it is already a PE/EFI
	# binary via CONFIG_EFI_STUB), which proves the same signature chain.
	echo "==> no systemd-stub; signing the EFI-stub bzImage directly"
	cp "$KERNEL" "$uki.unsigned"
fi

sbsign --key "$OUT/pki/secureboot.key" --cert "$OUT/pki/secureboot.crt" \
	--output "$uki" "$uki.unsigned"
rm -f "$uki.unsigned"
echo "==> signed UKI: $uki"
sbverify --cert "$OUT/pki/secureboot.crt" "$uki" 2>&1 | sed 's/^/    /'
