# KVM hypervisor host: runs guest VMs on bare metal.
DESC="KVM hypervisor host (bare metal, runs guest VMs)"
LAYERS="layer-hypervisor"
# Datapath throughput beats free-poisoning on this layer.
#
# opt-livepatch is on DELIBERATELY, and it reverses the no-modules stance.
# The reason is measurable, not cultural: in 7.2 the Live Update Orchestrator
# registers exactly one file handler (memfd), so a kexec-with-handover
# preserves guest memory but NOT an assigned device.  Any host doing SR-IOV or
# PCI passthrough therefore cannot fix a CVE without disrupting those guests --
# unless it can livepatch.  Drop this override on a fleet with no device
# assignment, or once LUO grows vfio/iommufd handover.
OVERRIDES="opt-datapath-perf opt-livepatch"
