# Scheduler: one large CPU-bound placement process, no local state.
DESC="Scheduler node (large in-memory state, CPU-bound placement loop)"
LAYERS="layer-scheduler"
# No forwarding, no local state, one trust domain.
OVERRIDES="strip-no-overlay strip-stateless"
