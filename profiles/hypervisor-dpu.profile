# Destination host SKU: the DPU terminates the overlay, so the host kernel
# never touches a tenant packet and carries no software dataplane.
DESC="KVM host with DPU (destination; no software dataplane)"
LAYERS="layer-hypervisor"
OVERRIDES="opt-datapath-perf opt-livepatch opt-dpu"
NICS="mellanox"
LIVEUPDATE="yes"
