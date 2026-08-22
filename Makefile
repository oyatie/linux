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
	-e PROFILE="$(PROFILE)" \
	-e MSV="$(MSV)" \
	$(IMAGE)

.PHONY: help image check-msv fetch config build validate validate-all msv unaudited menuconfig config-diff initramfs smoke shell clean distclean

help:
	@echo "kvmhost -- fleet kernels, currently pinned to linux-$(KERNEL_VERSION)"
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
	@echo "  make validate-all     resolve + verify every profile"
	@echo "  make msv              recompute the minimum supported kernel version"
	@echo "  make menuconfig       explore interactively on top of the resolved config"
	@echo "  make config-diff      show what menuconfig changed, as fragment lines"
	@echo "  make smoke            boot the built kernel under QEMU and assert on it"
	@echo "  make shell            drop into the build container"
	@echo
	@echo "  KERNEL_VERSION=7.3 make build      build against another release (>= MSV $(MSV))"
	@echo "  KVMHOST_EXTRA=opt-guest make build add optional fragments"
	@echo "  KVMHOST_NICS=mellanox make build     build only your fleet's NICs"
	@echo "  ACCEL=intel-dsa make build           add an accelerator (DSA/IAA, QAT)"

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
		echo "Live update (LIVEUPDATE/LIVEUPDATE_MEMFD) does not exist there." >&2; \
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
	@fail=0; \
	for p in profiles/*.profile; do \
		n=$$(basename $$p .profile); \
		printf '\n=========== %s @ linux-$(KERNEL_VERSION) ===========\n' "$$n"; \
		$(MAKE) --no-print-directory PROFILE=$$n config || fail=1; \
	done; \
	exit $$fail

initramfs: | $(OUT)
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro -v $(OUT):/out \
		$(IMAGE) /repo/scripts/mkinitramfs.sh

smoke: initramfs
	./scripts/qemu-smoke.sh $(OUT)/bzImage-$(PROFILE) $(OUT)/initramfs.cpio.gz

shell:
	docker run --rm -it -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-v $(OUT):/out -e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) bash

clean:
	rm -rf $(OUT)

distclean: clean
	-docker volume rm $(SRC_VOLUME)
