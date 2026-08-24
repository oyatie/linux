# The general-purpose engineer SKU -- the one kernel that must BOOT ON UNKNOWN
# MODERN HARDWARE (a laptop or desktop an engineer uses to operate the
# datacenter), the deliberate inverse of the fleet kernels.  Talos-like in
# spirit: minimal userland philosophy, hardened, signed -- but a *general*
# kernel, because it does not know the machine it lands on.  Base for a future
# engineer distro; NOT in the strict scoping-gate matrix (breadth vs zero-
# undecided are opposite goals -- this SKU chooses breadth).
DESC="Engineer workstation (general-purpose; boots modern laptops/desktops, hardened)"
LAYERS="layer-workstation"
OVERRIDES="hw-client"
PLATFORM="metal"
NICS="none"
