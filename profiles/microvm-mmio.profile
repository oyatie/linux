# Minimal guest: virtio-mmio only, no PCI/ACPI/EFI.  Boots only under a VMM
# that speaks the bare Linux boot protocol (Firecracker, crosvm).
DESC="MicroVM guest, MMIO-only (no PCI/ACPI/EFI, fastest boot)"
LAYERS="layer-microvm-mmio"
# Compression is deliberately NOT baked in here: it is an independent axis and
# baking it into the profile makes size comparisons between profiles lie.
# Add KVMHOST_EXTRA=opt-fastboot for LZ4 (faster decompress, ~10% larger).
OVERRIDES="strip-host strip-mmio"
NICS="none"
