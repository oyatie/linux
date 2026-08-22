# Minimal guest: virtio-mmio only, no PCI/ACPI/EFI.  Boots only under a VMM
# that speaks the bare Linux boot protocol (Firecracker, crosvm).
DESC="MicroVM guest, MMIO-only (no PCI/ACPI/EFI, fastest boot)"
LAYERS="layer-microvm-mmio"
OVERRIDES="strip-host strip-mmio opt-fastboot"
NICS="none"
