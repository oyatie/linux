# Transient, single-purpose kernel: the DPU/BMC forces a host into this image
# between tenants (BOOT_OVERRIDE) to run the decommission flow, then power off.
# Metal (it runs on the host being reclaimed), fenced (no NIC), no KVM, no live
# update.  Proven in QEMU with an emulated NVMe + swtpm; on real silicon the
# same driver paths drive the physical parts and the RoT performs the erase,
# scrub, and quote.  See the Basalt HSI: KEY_DESTROY / SANITIZE_START / QUOTE.
DESC="Reclaim/sanitize kernel (between-tenant wipe; NIST 800-88/193 + attest)"
LAYERS=""
OVERRIDES="strip-reclaim"
PLATFORM="metal"
NICS="none"
