# Worker node: runs tenant tasks in containers and sandboxes.
DESC="Worker node (runs tenant tasks: kubelet, Borglet)"
LAYERS="layer-worker"
# Same argument as the hypervisor: tenant tasks are expensive to evacuate and
# LUO cannot hand over their devices, so livepatch is the only zero-disruption
# fix path.  Requires MODULE_SIG_FORCE (set in the fragment) and the signing
# key held offline.
OVERRIDES="opt-livepatch"
