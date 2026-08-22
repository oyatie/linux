# The function/container-instance guest: Firecracker, virtio-mmio devices
# declared on the kernel command line, no PCI, no ACPI, no EFI.  Stays
# viciously small; general workloads belong on ch-guest.
DESC="Firecracker guest (v1; MMIO-only, no PCI/ACPI/EFI)"
LAYERS="layer-fc-guest"
OVERRIDES="strip-mmio strip-minimal-guest"
PLATFORM="vm"
NICS="none"
ARTIFACT="vmlinux"
