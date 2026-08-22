# Guest kernel for a microVM -- the thing that runs inside, not the host.
DESC="MicroVM guest (Firecracker/crosvm class, virtio only)"
LAYERS="layer-microvm"
OVERRIDES="strip-minimal-guest"
PLATFORM="vm"
NICS="none"
