# AI/HPC accelerator node: GPUs, RDMA fabric, out-of-tree vendor driver.
DESC="GPU/AI node (RDMA fabric, GPUDirect P2P, signed out-of-tree driver)"
LAYERS="layer-worker layer-gpu"
OVERRIDES="opt-livepatch"
NICS="mellanox"
