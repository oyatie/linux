# Guest kernel for a microVM -- the thing that runs inside, not the host.
DESC="MicroVM guest (Firecracker/crosvm class, virtio only)"
LAYERS="layer-microvm"
OVERRIDES="strip-host"
# No physical NICs: virtio-net is the only interface it will ever see.
NICS="none"
