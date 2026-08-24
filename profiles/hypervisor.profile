# The v1 plant kernel: bare-metal KVM host running Cloud Hypervisor and/or
# Firecracker VMMs.  Everything else in the fleet runs as a guest on top.
DESC="KVM hypervisor host (v1 plant; Cloud Hypervisor / Firecracker VMMs)"
LAYERS="layer-hypervisor"
# opt-livepatch reverses the no-modules stance, deliberately: LUO cannot hand
# over an assigned device (its only handler is memfd), so a VFIO host cannot
# fix a CVE without disrupting passthrough guests unless it can livepatch.
OVERRIDES="opt-datapath-perf opt-livepatch hw-cxl"
# Pin the fleet's actual NICs; override with KVMHOST_NICS= for other SKUs.
NICS="mellanox"
# Live update (KHO+LUO) on the destination track; ignored below LUO_FLOOR.
LIVEUPDATE="yes"
