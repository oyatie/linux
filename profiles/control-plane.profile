# Cluster control plane: the replicated state machine that owns cluster state.
DESC="Control-plane node (replicated state machine: etcd/apiserver, Borgmaster)"
LAYERS="layer-control-plane"
# Forwards no tenant traffic; encrypts east-west with mTLS, not IPsec.
OVERRIDES="strip-no-overlay"
