# KVM hypervisor host: runs guest VMs on bare metal.
DESC="KVM hypervisor host (bare metal, runs guest VMs)"
LAYERS="layer-hypervisor"
# Datapath throughput beats free-poisoning on this layer.
OVERRIDES="opt-datapath-perf"
