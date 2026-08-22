# GPU-VM host SKU (later): sells GPU instances by VFIO passthrough.  The GPU
# goes TO the guest, so this host binds no GPU driver and carries no DRM --
# build.sh refuses GPU= on this profile.  Differences from `hypervisor` are
# runtime (1G hugepages sized for VRAM-adjacent guests, vfio-pci binding,
# pci=realloc for big BARs), not config.
DESC="GPU-VM host (later SKU; GPUs passed through via VFIO, no host GPU driver)"
LAYERS="layer-hypervisor"
OVERRIDES="opt-datapath-perf opt-livepatch"
NICS="mellanox"
LIVEUPDATE="yes"
