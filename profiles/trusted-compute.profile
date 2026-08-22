# First-party compute node: no tenant code, no sandboxes, DMA untranslated.
DESC="Trusted compute node (first-party workloads only, IOMMU passthrough)"
LAYERS="layer-worker"
OVERRIDES="opt-trusted opt-livepatch"
