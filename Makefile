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
KVMHOST_EXTRA  ?=

DOCKER_RUN = docker run --rm \
	-v $(SRC_VOLUME):/build \
	-v $(CURDIR):/repo:ro \
	-v $(OUT):/out \
	-e KERNEL_VERSION=$(KERNEL_VERSION) \
	-e SRC=/build/linux-$(KERNEL_VERSION) \
	$(if $(JOBS),-e JOBS=$(JOBS)) \
	-e KVMHOST_EXTRA="$(KVMHOST_EXTRA)" \
	$(IMAGE)

.PHONY: help image fetch config build validate validate-matrix menuconfig config-diff initramfs smoke shell clean distclean

help:
	@echo "kvmhost -- KVM host kernel, currently pinned to linux-$(KERNEL_VERSION)"
	@echo
	@echo "  make image            build the container toolchain"
	@echo "  make fetch            download + unpack the kernel source"
	@echo "  make config           resolve fragments -> .config, verify, stop"
	@echo "  make build            config + compile bzImage into out/"
	@echo "  make validate         config-only check against the pinned version"
	@echo "  make validate-matrix  same, against every version in configs/kernel.pin"
	@echo "  make menuconfig       explore interactively on top of the resolved config"
	@echo "  make config-diff      show what menuconfig changed, as fragment lines"
	@echo "  make smoke            boot the built kernel under QEMU and assert on it"
	@echo "  make shell            drop into the build container"
	@echo
	@echo "  KERNEL_VERSION=7.2 make build      build against mainline instead"
	@echo "  KVMHOST_EXTRA=opt-guest make build add optional fragments"

image:
	docker build -t $(IMAGE) -f docker/Dockerfile docker

$(OUT):
	@mkdir -p $(OUT)

fetch:
	@docker volume create $(SRC_VOLUME) >/dev/null
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) /repo/scripts/fetch.sh

config: fetch | $(OUT)
	$(DOCKER_RUN) sh -c 'CONFIG_ONLY=1 /repo/scripts/build.sh'

build: fetch | $(OUT)
	$(DOCKER_RUN) /repo/scripts/build.sh

validate: config

validate-matrix: | $(OUT)
	@for v in $$(sed -n 's/^#   \([0-9][0-9.]*\) .*/\1/p' configs/kernel.pin); do \
		echo "=================== linux-$$v ==================="; \
		$(MAKE) --no-print-directory KERNEL_VERSION=$$v config || exit 1; \
	done

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

initramfs: | $(OUT)
	docker run --rm -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro -v $(OUT):/out \
		$(IMAGE) /repo/scripts/mkinitramfs.sh

smoke: initramfs
	./scripts/qemu-smoke.sh $(OUT)/bzImage $(OUT)/initramfs.cpio.gz

shell:
	docker run --rm -it -v $(SRC_VOLUME):/build -v $(CURDIR):/repo:ro \
		-v $(OUT):/out -e KERNEL_VERSION=$(KERNEL_VERSION) $(IMAGE) bash

clean:
	rm -rf $(OUT)

distclean: clean
	-docker volume rm $(SRC_VOLUME)
