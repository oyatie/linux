# Minimal guest: virtio-mmio only, no PCI/ACPI/EFI.  Boots only under a VMM
# that speaks the bare Linux boot protocol (Firecracker, crosvm).
DESC="MicroVM guest, MMIO-only (no PCI/ACPI/EFI, fastest boot)"
LAYERS="layer-microvm-mmio"
# Compression is deliberately NOT baked in: add KVMHOST_EXTRA=opt-fastboot
# for LZ4 (faster decompress, ~10% larger).
OVERRIDES="strip-mmio strip-minimal-guest"
PLATFORM="vm"
NICS="none"
