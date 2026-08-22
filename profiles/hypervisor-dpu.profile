# KVM host whose dataplane lives on a DPU/SmartNIC.
DESC="KVM hypervisor host with DPU (no software dataplane)"
LAYERS="layer-hypervisor"
OVERRIDES="opt-datapath-perf opt-dpu"
