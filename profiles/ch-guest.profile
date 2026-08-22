# The general guest: sold VMs and first-party serving under Cloud Hypervisor.
# Full virtio-pci + ACPI (hotplug), NUMA and big NR_CPUS inherited from base,
# kTLS on, NVMe + virtio-blk as the SKU presents.  Deliberately NOT minimal:
# this is a general-purpose kernel that happens to live in a VM.
DESC="Cloud Hypervisor guest (v1; sold VMs and first-party serving)"
LAYERS="layer-ch-guest"
OVERRIDES=""
PLATFORM="vm"
NICS="none"
# FC/CH direct-boot wants an ELF vmlinux, not only a bzImage.
ARTIFACT="vmlinux"
