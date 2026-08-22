# Later SKU, only if we sell managed kube: a node image that runs containers
# INSIDE a CH guest -- the container stack in a VM, not on metal.
DESC="Kubernetes node guest (later SKU; container stack inside a CH guest)"
LAYERS="layer-ch-guest layer-containers"
OVERRIDES=""
PLATFORM="vm"
NICS="none"
ARTIFACT="vmlinux"
