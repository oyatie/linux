# Later SKU, only if we sell managed kube: a node image that runs containers
# INSIDE a CH guest -- the container stack in a VM, not on metal.
DESC="Kubernetes node guest (later SKU; container stack inside a CH guest)"
LAYERS="layer-ch-guest layer-containers"
# net-cni adds the pod-overlay encap devices (VXLAN/GENEVE + WireGuard mesh,
# MACVLAN/IPVLAN) an overlay CNI needs.  Here, not in layer-containers, because
# that layer is shared with trusted-compute (metal services, no pod overlay);
# only the kube-node SKU gets the encap surface.
OVERRIDES="net-cni"
PLATFORM="vm"
NICS="none"
ARTIFACT="vmlinux"
