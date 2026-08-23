# kvmhost -- a stripped-down Linux kernel for KVM hypervisor hosts.
#
# Everything runs in a container: the kernel tree cannot live on a
# case-insensitive filesystem, and a reproducible fleet kernel should not
# depend on whatever toolchain the developer happens to have.

include configs/kernel.pin

IMAGE          := kvmhost-build
SRC_VOLUME     := kvmhost-src
OUT            := $(CURDIR)/out
# Deliberately NOT the host's core count: the build runs inside a VM that
# usually has fewer CPUs and much less RAM than the host, and over-subscribing
# -j there gets cc1 OOM-killed.  build.sh defaults to the container's nproc;
# set JOBS=N here only to override that.
JOBS           ?=
PROFILE        ?= hypervisor
# Target architecture: x86_64 (default) or arm64 (Graviton/Ampere/Grace).
KARCH          ?= x86_64
# Destination-track artifacts get a -dst suffix so the two tracks coexist in
# out/ -- learned after a 7.2 build silently overwrote the v1 bzImage.
TRACK_TAG      := $(if $(filter $(DESTINATION_VERSION),$(KERNEL_VERSION)),dst,)
KVMHOST_EXTRA  ?=
# Which NIC families to build in.  Empty = all of them (portable image).
KVMHOST_NICS   ?=

DOCKER_RUN = docker run --rm \
	-v $(SRC_VOLUME):/build \
	-v $(CURDIR):/repo:ro \
	-v $(OUT):/out \
	-e KERNEL_VERSION=$(KERNEL_VERSION) \
	-e SRC=/build/linux-$(KERNEL_VERSION) \
	$(if $(JOBS),-e JOBS=$(JOBS)) \
	-e KVMHOST_EXTRA="$(KVMHOST_EXTRA)" \
	-e KVMHOST_NICS="$(KVMHOST_NICS)" \
	-e KVMHOST_ACCEL="$(ACCEL)" \
	-e KVMHOST_GPU="$(GPU)" \
	-e KVMHOST_CPU="$(CPU)" \
	-e KVMHOST_PLATFORM="$(PLATFORM)" \
	-e KVMHOST_ARCH="$(KARCH)" \
	-e KVMHOST_TRACK="$(TRACK_TAG)" \
	-e PROFILE="$(PROFILE)" \
	-e MSV="$(MSV)" \
	-e LUO_FLOOR="$(LUO_FLOOR)" \
	$(IMAGE)

.PHONY: help image check-msv fetch config build validate validate-all msv audit audit-list hardening unaudited unused menuconfig config-diff initramfs smoke smoke-fc shell clean tree-clean distclean

help:
	@echo "kvmhost -- fleet kernels.  v1 track: linux-$(KERNEL_VERSION) (LTS);"
	@echo "destination track: linux-$(DESTINATION_VERSION) (KHO+LUO live update)."
	@echo
	@echo "Profiles (PROFILE=<name>, default $(PROFILE)):"
	@for p in profiles/*.profile; do \
		n=$$(basename $$p .profile); \
		d=$$(sed -n 's/^DESC="\(.*\)"/\1/p' $$p); \
		printf "  %-14s %s\n" "$$n" "$$d"; \
	done
	@echo
	@echo "  make image            build the container toolchain"
	@echo "  make fetch            download + unpack the kernel source"
	@echo "  make config           resolve fragments -> .config, verify, stop"
	@echo "  make build            config + compile bzImage into out/"
	@echo "  make validate         config-only check against the pinned version"
	@echo "  make validate-all     resolve + verify the shippable matrix on both tracks"
	@echo "  make msv              recompute the minimum supported kernel version"
	@echo "  make unused           fail if any fragment is unreachable"
	@echo "  make audit            fail if any default-on feature is un-accounted"
	@echo "  make hardening        third-party KSPP/CLIP/grsec score of PROFILE"
	@echo "  make menuconfig       explore interactively on top of the resolved config"
	@echo "  make config-diff      show what menuconfig changed, as fragment lines"
	@echo "  make smoke            boot the built kernel under QEMU and assert on it"
	@echo "  make shell            drop into the build container"
	@echo
	@echo "  KERNEL_VERSION=$(DESTINATION_VERSION) make build   build the destination track (>= MSV $(MSV))"
	@echo "  KVMHOST_EXTRA=opt-windows make build add optional fragments (opt-rt, opt-lowmem, ...)"
	@echo "  KVMHOST_NICS=mellanox make build     build only your fleet's NICs"
	@echo "  ACCEL=intel-dsa make build           add an accelerator (DSA/IAA, QAT)"
	@echo "  GPU=nvidia|amd make build            add GPU support (see docs/PROVIDERS.md)"
	@echo "  CPU=intel|amd make build             single-vendor fleet (default: both)"
	@echo "  PLATFORM=vm make build               this kernel runs inside a VM, not on metal"
	@echo "  KARCH=arm64 make build               Graviton/Ampere-class target"

image:
	docker build -t $(IMAGE) -f docker/Dockerfile docker

$(OUT):
	@mkdir -p $(OUT)

# Enforced here rather than only in build.sh so that an out-of-range version
# fails before downloading 150MB of source.
check-msv:
	@kv="$(KERNEL_VERSION)"; msv="$(MSV)"; \
	kvn=$$(printf '%d%03d' $${kv%%.*} $$(echo $$kv | cut -d. -f2)); \
	msvn=$$(printf '%d%03d' $${msv%%.*} $$(echo $$msv | cut -d. -f2)); \
	if [ "$$kvn" -lt "$$msvn" ]; then \
		echo "kernel $$kv is below the minimum supported version $$msv" >&2; \
		echo "(v1 feature floor -- iommufd/cdev, KVM TDX, PREEMPT_LAZY.  docs/MSV.md)" >&2; \
		echo "See docs/MSV.md; regenerate the floor with 'make msv'." >&2; \
		exit 1; \
	fi

fetch: check-msv
	@docker volume create $(SRC_VOLUME) >/dev/null
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) /repo/scripts/fetch.sh

config: fetch | $(OUT)
	$(DOCKER_RUN) sh -c 'CONFIG_ONLY=1 /repo/scripts/build.sh'

build: fetch | $(OUT)
	$(DOCKER_RUN) /repo/scripts/build.sh

validate: config

msv:
	./scripts/feature-floor.sh

# Fail if a fragment exists that no profile or knob can select.
unused:
	./scripts/unused-fragments.sh

# Independent third-party hardening score (KSPP/CLIP/grsec) of the current
# PROFILE.  Fetches the checker into a cache on first use.
hardening: config
	./scripts/hardening-check.sh $(PROFILE)

# The scoping gate: every default-on feature must be requested, implied, or in
# configs/accept-defaults.config.  Runs against the current PROFILE/KARCH.
audit: config
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro $(IMAGE) sh -c \
		'python3 /repo/scripts/unaudited.py --strict \
			--accept /repo/configs/accept-defaults.config \
			/build/linux-$(KERNEL_VERSION) /build/linux-$(KERNEL_VERSION)/.config \
			/repo/configs/fragments/*.config'

# Print default-on features not yet in the ledger (to extend it).
audit-list: config
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro $(IMAGE) sh -c \
		'python3 /repo/scripts/unaudited.py --accept /repo/configs/accept-defaults.config \
			/build/linux-$(KERNEL_VERSION) /build/linux-$(KERNEL_VERSION)/.config \
			/repo/configs/fragments/*.config'"'"

# Classify every enabled symbol: requested by a fragment, implied by a select,
# or arrived from a Kconfig default with nobody looking.
unaudited: config
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro $(IMAGE) sh -c \
		'python3 /repo/scripts/unaudited.py /build/linux-$(KERNEL_VERSION) \
		/build/linux-$(KERNEL_VERSION)/.config /repo/configs/fragments/*.config'

# Interactive exploration only.  menuconfig is not how this kernel is
# configured -- an interactive session is not reviewable, not reproducible in
# CI, and records no reason for any choice.  Use it to find a symbol or check
# a dependency, then run `make config-diff` and fold the result into a
# fragment with a comment saying why.
menuconfig: config
	docker run --rm -it -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-v $(OUT):/out -e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) \
		sh -c 'cd /build/linux-$(KERNEL_VERSION) && make ARCH=x86_64 menuconfig'
	@$(MAKE) --no-print-directory config-diff

config-diff:
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro -v $(OUT):/out \
		-e SRC=/build/linux-$(KERNEL_VERSION) $(IMAGE) /repo/scripts/config-diff.sh

validate-all: | $(OUT)
	VALIDATE_VERSIONS="$(KERNEL_VERSION) $(DESTINATION_VERSION)" ./scripts/validate-matrix.sh

# The initramfs embeds that arch's host kernel as the kexec-probe target --
# a real unsigned image is the only thing that reaches the KEXEC_SIG gate.
PROBE_KERNEL = $(if $(filter arm64,$(KARCH)),Image-hypervisor-arm64,bzImage-hypervisor)
initramfs: | $(OUT)
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro -v $(OUT):/out \
		-e KVMHOST_ARCH=$(KARCH) -e PROBE_KERNEL=$(PROBE_KERNEL) \
		$(IMAGE) /repo/scripts/mkinitramfs.sh

# Guest profiles assert a guest-shaped kernel (no KVM, no modules); fc-guest
# boots on QEMU's microvm machine, the faithful stand-in for Firecracker's
# virtio-mmio world.  scripts/fc-smoke.sh runs the REAL VMM on a Linux+KVM box.
SMOKE_MACHINE = $(if $(filter fc-guest,$(PROFILE)),microvm,q35)
SMOKE_EXPECT  = $(if $(filter ch-guest ch-guest-k8s fc-guest,$(PROFILE)),guest,host)
SMOKE_SUFFIX  = $(PROFILE)$(if $(TRACK_TAG),-$(TRACK_TAG))$(if $(filter arm64,$(KARCH)),-arm64)
SMOKE_KERNEL  = $(if $(filter arm64,$(KARCH)),$(OUT)/Image-$(SMOKE_SUFFIX),$(OUT)/bzImage-$(SMOKE_SUFFIX))
# kexec policy differs per SKU: hosts must be sig-gated (eperm), fc-guest has
# no kexec syscall at all (enosys), ch-guest keeps plain kdump -- root in a
# guest owns the guest kernel anyway (enoexec = parsed, no gate).
# hosts: unsigned image refused at the gate (eperm).  ch-guest: no gate by
# design (root owns the guest kernel) -- the unsigned image loads.  fc-guest:
# no syscall at all.
SMOKE_KEXEC   = $(if $(filter fc-guest,$(PROFILE)),enosys,$(if $(filter ch-guest ch-guest-k8s,$(PROFILE)),loaded,eperm))
smoke: initramfs
	KARCH=$(KARCH) MACHINE=$(SMOKE_MACHINE) EXPECT=$(SMOKE_EXPECT) \
	KVER=$(KERNEL_VERSION) LUO_FLOOR=$(LUO_FLOOR) KEXEC_WANT=$(SMOKE_KEXEC) \
		./scripts/qemu-smoke.sh $(SMOKE_KERNEL) $(OUT)/initramfs-$(KARCH).cpio.gz

smoke-fc:
	./scripts/fc-smoke.sh $(OUT)/vmlinux-fc-guest $(OUT)/initramfs.cpio.gz

shell:
	docker run --rm -it -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-v $(OUT):/out -e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) bash

clean:
	rm -rf $(OUT)

# Scrub the shared volume's kernel object tree (keeps the source).  Needed
# after an interrupted build: a SIGKILL mid-write leaves half-written *.cmd
# files that later detonate as "unterminated variable reference" in an
# unrelated subsystem.  Cheaper than distclean (which re-downloads source).
tree-clean:
	docker run --rm -v $(SRC_VOLUME):/build $(IMAGE) sh -c \
		'cd /build/linux-$(KERNEL_VERSION) && make -s ARCH=$(KARCH) clean'

distclean: clean
	-docker volume rm $(SRC_VOLUME)
