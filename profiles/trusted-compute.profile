# Later SKU: first-party services on metal.  One trust domain, so DMA runs
# untranslated (IOMMU passthrough) and there is no KVM -- nothing to sandbox.
# First-party AI training is this profile plus GPU=nvidia|amd.
DESC="Trusted compute node (later SKU; first-party only, IOMMU passthrough)"
LAYERS="layer-containers"
OVERRIDES="opt-trusted"
NICS="mellanox"
